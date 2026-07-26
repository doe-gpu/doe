"""Gerrit and Chromium Issue Tracker source adapters."""

from __future__ import annotations

import json
import urllib.parse
from collections.abc import Callable, Iterable
from datetime import datetime, timezone
from typing import Any

from pipeline.upstream_intelligence.io import HttpClient


class IssueUnavailableError(ValueError):
    """The public issue route exists but exposes no issue payload."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class GerritClient:
    def __init__(self, config: dict[str, Any], http: HttpClient) -> None:
        self.config = config
        self.http = http

    def changes(
        self,
        query: str,
        *,
        on_page: Callable[[list[dict[str, Any]], int], None] | None = None,
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        page_size = int(self.config["pageSize"])
        max_pages = int(self.config["maxPages"])
        options = [
            "CURRENT_REVISION",
            "CURRENT_COMMIT",
            "CURRENT_FILES",
        ]
        for page_index in range(max_pages):
            parameters: list[tuple[str, str]] = [
                ("q", query),
                ("n", str(page_size)),
                ("S", str(page_index * page_size)),
            ]
            parameters.extend(("o", option) for option in options)
            url = (
                str(self.config["baseUrl"]).rstrip("/")
                + "/changes/?"
                + urllib.parse.urlencode(parameters)
            )
            page = self.http.get_json(url, gerrit_prefix=True)
            if not isinstance(page, list):
                raise ValueError("Gerrit changes response must be an array")
            typed_page = [item for item in page if isinstance(item, dict)]
            if on_page:
                on_page(typed_page, page_index)
            result.extend(typed_page)
            more = bool(typed_page and typed_page[-1].get("_more_changes"))
            if not more:
                return result
        if result and result[-1].get("_more_changes"):
            raise RuntimeError(
                f"Gerrit pagination incomplete after configured maxPages={max_pages}"
            )
        return result


def extract_json_assignment(page: str, marker: str) -> Any:
    start = page.find(marker)
    if start < 0:
        raise ValueError(f"page does not contain {marker!r}")
    array_start = page.find("[", start + len(marker))
    if array_start < 0:
        raise ValueError("assignment does not contain a JSON array")
    depth = 0
    in_string = False
    escaped = False
    for index in range(array_start, len(page)):
        character = page[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "[":
            depth += 1
        elif character == "]":
            depth -= 1
            if depth == 0:
                return json.loads(page[array_start : index + 1])
    raise ValueError("unterminated JSON array assignment")


def _walk_lists(value: Any) -> Iterable[list[Any]]:
    if isinstance(value, list):
        yield value
        for item in value:
            yield from _walk_lists(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from _walk_lists(item)


def _timestamp(value: Any) -> str:
    if not isinstance(value, list) or not value or not isinstance(value[0], int):
        return ""
    return datetime.fromtimestamp(value[0], tz=timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def parse_chromium_issue(page: str, issue_id: int) -> dict[str, Any]:
    resources = extract_json_assignment(page, "var defrostedResourcesJspb = ")
    if resources == [None, True]:
        raise IssueUnavailableError(
            f"issue {issue_id} is not publicly available or does not exist"
        )
    root: list[Any] | None = None
    for candidate in _walk_lists(resources):
        if (
            len(candidate) > 6
            and candidate[1] == issue_id
            and isinstance(candidate[2], list)
            and len(candidate[2]) > 6
            and isinstance(candidate[2][5], str)
        ):
            root = candidate
            break
    if root is None:
        raise ValueError(f"IssueFetchResponse for issue {issue_id} was not found")
    detail = root[2]
    descriptions: list[str] = []
    for candidate in _walk_lists(root[8:]):
        descriptions.extend(item for item in candidate if isinstance(item, str))
    description = max(descriptions, key=len, default="")
    return {
        "id": issue_id,
        "url": f"https://issues.chromium.org/issues/{issue_id}",
        "componentId": detail[0] if isinstance(detail[0], int) else None,
        "title": detail[5],
        "created": _timestamp(root[4]),
        "updated": _timestamp(root[5]),
        "description": description,
    }


class ChromiumIssueClient:
    def __init__(self, config: dict[str, Any], http: HttpClient) -> None:
        self.config = config
        self.http = http

    def issue(self, issue_id: int) -> dict[str, Any]:
        url = f"{str(self.config['baseUrl']).rstrip('/')}/{issue_id}"
        page = self.http.request(url).decode("utf-8")
        issue = parse_chromium_issue(page, issue_id)
        issue["description"] = issue["description"][
            : int(self.config["maxDescriptionCharacters"])
        ]
        return issue
