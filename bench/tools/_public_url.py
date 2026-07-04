"""Shared public URL validation for browser release evidence."""

from __future__ import annotations

import ipaddress
from typing import Any
from urllib.parse import urlparse


SPECIAL_USE_HOSTS = {
    "example",
    "invalid",
    "localhost",
    "test",
}
SPECIAL_USE_DOMAINS = (
    "example.com",
    "example.net",
    "example.org",
)
SPECIAL_USE_SUFFIXES = (
    ".example",
    ".invalid",
    ".local",
    ".localhost",
    ".test",
)


def is_public_https_url(url_text: Any) -> bool:
    if not isinstance(url_text, str) or not url_text:
        return False
    parsed = urlparse(url_text)
    if parsed.scheme != "https" or not parsed.netloc:
        return False
    if parsed.username is not None or parsed.password is not None:
        return False
    hostname = parsed.hostname
    if not isinstance(hostname, str) or not hostname:
        return False
    host = hostname.rstrip(".").lower()
    if host in SPECIAL_USE_HOSTS or any(host.endswith(suffix) for suffix in SPECIAL_USE_SUFFIXES):
        return False
    if any(host == domain or host.endswith(f".{domain}") for domain in SPECIAL_USE_DOMAINS):
        return False
    try:
        return ipaddress.ip_address(host).is_global
    except ValueError:
        return "." in host
