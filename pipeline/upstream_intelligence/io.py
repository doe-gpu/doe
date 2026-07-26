"""Deterministic artifact and transport helpers."""

from __future__ import annotations

import hashlib
import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_json(value: object) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


class HttpClient:
    """Small retrying HTTP client with all policy supplied by configuration."""

    def __init__(
        self,
        *,
        timeout_seconds: int,
        retry_count: int,
        retry_backoff_seconds: float,
        user_agent: str,
    ) -> None:
        self.timeout_seconds = timeout_seconds
        self.retry_count = retry_count
        self.retry_backoff_seconds = retry_backoff_seconds
        self.user_agent = user_agent

    def request(
        self,
        url: str,
        *,
        method: str = "GET",
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> bytes:
        request_headers = {"User-Agent": self.user_agent}
        request_headers.update(headers or {})
        request = urllib.request.Request(
            url,
            data=body,
            headers=request_headers,
            method=method,
        )
        last_error: Exception | None = None
        for attempt in range(self.retry_count + 1):
            try:
                with urllib.request.urlopen(
                    request,
                    timeout=self.timeout_seconds,
                ) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                last_error = error
                retryable = error.code in {408, 429} or 500 <= error.code <= 599
                if not retryable or attempt == self.retry_count:
                    break
                time.sleep(self.retry_backoff_seconds * (2**attempt))
            except (urllib.error.URLError, TimeoutError) as error:
                last_error = error
                if attempt == self.retry_count:
                    break
                time.sleep(self.retry_backoff_seconds * (2**attempt))
        raise RuntimeError(f"request failed after retries: {url}: {last_error}")

    def get_json(self, url: str, *, gerrit_prefix: bool = False) -> Any:
        text = self.request(url).decode("utf-8")
        if gerrit_prefix:
            if not text.startswith(")]}'"):
                raise ValueError(f"Gerrit response lacks anti-XSSI prefix: {url}")
            text = text.split("\n", 1)[1]
        return json.loads(text)

    def post_json(self, url: str, value: object, bearer_token: str) -> Any:
        response = self.request(
            url,
            method="POST",
            body=canonical_json(value).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {bearer_token}",
                "Content-Type": "application/json",
                "Idempotency-Key": sha256_json(value),
            },
        )
        return json.loads(response.decode("utf-8"))
