"""Durable, update-aware state for upstream intelligence."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Iterable

from pipeline.upstream_intelligence.io import canonical_json, sha256_json


SCHEMA_VERSION = 1


class IntelligenceStore:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA foreign_keys = ON")
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events (
                source TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                version TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY (source, entity_id, version)
            );
            CREATE UNIQUE INDEX IF NOT EXISTS events_content_identity
                ON events(source, entity_id, content_hash);
            CREATE TABLE IF NOT EXISTS findings (
                finding_id TEXT PRIMARY KEY,
                input_hash TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                payload TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS enrichments (
                finding_id TEXT NOT NULL,
                input_hash TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY (finding_id, input_hash, provider, model, prompt_version)
            );
            CREATE TABLE IF NOT EXISTS cursors (
                source TEXT NOT NULL,
                query_id TEXT NOT NULL,
                high_watermark TEXT NOT NULL,
                complete INTEGER NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (source, query_id)
            );
            CREATE TABLE IF NOT EXISTS promotions (
                receipt_id TEXT PRIMARY KEY,
                finding_id TEXT NOT NULL,
                payload TEXT NOT NULL
            );
            """
        )
        row = self.connection.execute(
            "SELECT value FROM metadata WHERE key = 'schema_version'"
        ).fetchone()
        if row is None:
            self.connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
        elif int(row["value"]) != SCHEMA_VERSION:
            raise RuntimeError(
                f"unsupported intelligence database schema {row['value']}"
            )
        self.connection.commit()

    def close(self) -> None:
        self.connection.close()

    def __enter__(self) -> "IntelligenceStore":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def put_event(
        self,
        source: str,
        entity_id: str,
        version: str,
        observed_at: str,
        payload: dict[str, Any],
    ) -> bool:
        content_hash = sha256_json(payload)
        cursor = self.connection.execute(
            """
            INSERT OR IGNORE INTO events
                (source, entity_id, version, content_hash, observed_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                source,
                entity_id,
                version,
                content_hash,
                observed_at,
                canonical_json(payload),
            ),
        )
        self.connection.commit()
        return cursor.rowcount == 1

    def latest_event(self, source: str, entity_id: str) -> dict[str, Any] | None:
        row = self.connection.execute(
            """
            SELECT payload FROM events
            WHERE source = ? AND entity_id = ?
            ORDER BY observed_at DESC, rowid DESC LIMIT 1
            """,
            (source, entity_id),
        ).fetchone()
        return json.loads(row["payload"]) if row else None

    def event_versions(self, source: str, entity_id: str) -> list[str]:
        rows = self.connection.execute(
            """
            SELECT version FROM events
            WHERE source = ? AND entity_id = ? ORDER BY version
            """,
            (source, entity_id),
        )
        return [str(row["version"]) for row in rows]

    def iter_latest_events(self, source: str) -> Iterable[dict[str, Any]]:
        rows = self.connection.execute(
            """
            SELECT payload FROM events
            WHERE source = ?
              AND rowid IN (
                SELECT MAX(rowid) FROM events
                WHERE source = ? GROUP BY entity_id
              )
            ORDER BY entity_id
            """,
            (source, source),
        )
        for row in rows:
            yield json.loads(row["payload"])

    def put_finding(self, finding: dict[str, Any]) -> None:
        self.connection.execute(
            """
            INSERT INTO findings(finding_id, input_hash, updated_at, payload)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(finding_id) DO UPDATE SET
                input_hash=excluded.input_hash,
                updated_at=excluded.updated_at,
                payload=excluded.payload
            """,
            (
                finding["findingId"],
                finding["inputHash"],
                finding["updatedAt"],
                canonical_json(finding),
            ),
        )
        self.connection.commit()

    def get_finding(self, finding_id: str) -> dict[str, Any] | None:
        row = self.connection.execute(
            "SELECT payload FROM findings WHERE finding_id = ?",
            (finding_id,),
        ).fetchone()
        return json.loads(row["payload"]) if row else None

    def iter_findings(self) -> Iterable[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT payload FROM findings ORDER BY finding_id"
        )
        for row in rows:
            yield json.loads(row["payload"])

    def get_enrichment(
        self,
        *,
        finding_id: str,
        input_hash: str,
        provider: str,
        model: str,
        prompt_version: str,
    ) -> dict[str, Any] | None:
        row = self.connection.execute(
            """
            SELECT payload FROM enrichments
            WHERE finding_id = ? AND input_hash = ? AND provider = ?
              AND model = ? AND prompt_version = ?
            """,
            (finding_id, input_hash, provider, model, prompt_version),
        ).fetchone()
        return json.loads(row["payload"]) if row else None

    def put_enrichment(self, enrichment: dict[str, Any]) -> None:
        self.connection.execute(
            """
            INSERT OR REPLACE INTO enrichments
                (finding_id, input_hash, provider, model, prompt_version, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                enrichment["findingId"],
                enrichment["inputHash"],
                enrichment["provider"],
                enrichment["model"],
                enrichment["promptVersion"],
                canonical_json(enrichment),
            ),
        )
        self.connection.commit()

    def set_cursor(
        self,
        source: str,
        query_id: str,
        high_watermark: str,
        complete: bool,
        updated_at: str,
    ) -> None:
        previous = self.get_cursor(source, query_id)
        if previous and previous["highWatermark"] > high_watermark:
            high_watermark = previous["highWatermark"]
        self.connection.execute(
            """
            INSERT INTO cursors(source, query_id, high_watermark, complete, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source, query_id) DO UPDATE SET
                high_watermark=excluded.high_watermark,
                complete=excluded.complete,
                updated_at=excluded.updated_at
            """,
            (source, query_id, high_watermark, int(complete), updated_at),
        )
        self.connection.commit()

    def get_cursor(self, source: str, query_id: str) -> dict[str, Any] | None:
        row = self.connection.execute(
            """
            SELECT high_watermark, complete, updated_at FROM cursors
            WHERE source = ? AND query_id = ?
            """,
            (source, query_id),
        ).fetchone()
        if not row:
            return None
        return {
            "highWatermark": row["high_watermark"],
            "complete": bool(row["complete"]),
            "updatedAt": row["updated_at"],
        }

    def put_promotion(self, receipt: dict[str, Any]) -> None:
        self.connection.execute(
            """
            INSERT INTO promotions(receipt_id, finding_id, payload)
            VALUES (?, ?, ?)
            """,
            (
                receipt["receiptId"],
                receipt["findingId"],
                canonical_json(receipt),
            ),
        )
        self.connection.commit()

    def counts(self) -> dict[str, int]:
        safe_tables = ("events", "findings", "enrichments", "cursors", "promotions")
        return {
            table: int(
                self.connection.execute(
                    f"SELECT COUNT(*) FROM {table}"
                ).fetchone()[0]
            )
            for table in safe_tables
        }
