import json
import logging

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def test_root():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["message"] == "Hello from DevOps Task!"
    assert body["status"] == "running"
    assert body["version"] == main.APP_VERSION


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_metrics_exposes_required_series():
    client.get("/")
    text = client.get("/metrics").text
    assert "http_requests_total" in text
    assert "http_errors_total" in text
    assert "http_request_duration_seconds_bucket" in text


def test_unknown_path_uses_bounded_label():
    client.get("/does-not-exist-123")
    assert 'path="unmatched"' in client.get("/metrics").text


def test_json_formatter_outputs_valid_json():
    record = logging.LogRecord("app", logging.INFO, "f", 1, "hello", None, None)
    record.fields = {"path": "/x", "status": 200}
    out = json.loads(main.JsonFormatter().format(record))
    assert out["level"] == "info" and out["path"] == "/x" and out["msg"] == "hello"


def test_fault_injection_disabled_by_default():
    assert client.get("/debug/error").status_code == 404


def test_fault_injection_when_enabled(monkeypatch):
    monkeypatch.setenv("ENABLE_FAULT_INJECTION", "true")
    assert client.get("/debug/error").status_code == 500
    assert 'http_errors_total{method="GET",path="/debug/error"}' in client.get("/metrics").text
