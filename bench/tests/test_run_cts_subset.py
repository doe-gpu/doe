#!/usr/bin/env python3
"""Tests for the configured CTS subset runner."""

from __future__ import annotations

from bench.runners import run_cts_subset as runner


def test_parse_adapter_identity_materializes_physical_fields() -> None:
    payload = runner.parse_adapter_identity(
        [
            "provider setup",
            '{"schemaVersion":1,"artifactKind":"webgpu_cts_adapter_identity",'
            '"provider":"fawn-node-gpu-provider","adapterInfo":{'
            '"vendor":"AMD","device":"Radeon","description":"RADV",'
            '"vendorID":4098,"deviceID":5510,"driverVersion":109051907}}',
        ]
    )

    assert payload["adapterInfo"]["vendorID"] == 4098
    assert payload["adapterInfo"]["deviceID"] == 5510
    assert payload["adapterInfo"]["driverVersion"] == 109051907


def test_parse_adapter_identity_rejects_incomplete_identity() -> None:
    try:
        runner.parse_adapter_identity(
            [
                '{"schemaVersion":1,"artifactKind":"webgpu_cts_adapter_identity",'
                '"provider":"fawn-node-gpu-provider","adapterInfo":{'
                '"vendor":"AMD","device":"Radeon"}}',
            ]
        )
    except ValueError as exc:
        assert "missing non-empty fields: description" in str(exc)
    else:
        raise AssertionError("incomplete adapter identity should be rejected")


def test_load_identity_probe_requires_explicit_policy() -> None:
    try:
        runner.load_identity_probe({"commandTemplate": "node probe.cjs"})
    except ValueError as exc:
        assert "identityProbe.required" in str(exc)
    else:
        raise AssertionError("identity probe without explicit policy should be rejected")
