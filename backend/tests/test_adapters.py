import asyncio
import json
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

import httpx
import pytest

from app.assistant import bedrock_intent
from app.config import Settings
from app.models import IntentRequest, SearchRequest
from datetime import date, timedelta


def test_bedrock_uses_converse_and_validates_schema(monkeypatch):
    current = SearchRequest(date=date.today() + timedelta(days=7))
    response_body = current.model_dump(mode="json")
    response_body["category"] = "cinema"
    runtime = MagicMock()
    runtime.converse.return_value = {"output": {"message": {"content": [{"text": json.dumps(response_body)}]}}}
    create_client = MagicMock(return_value=runtime)
    monkeypatch.setattr("boto3.client", create_client)
    result = bedrock_intent(IntentRequest(message="a movie please", current=current), Settings(bedrock_model="test-model"))
    assert result.category.value == "cinema"
    assert create_client.call_args.kwargs["region_name"] == "us-west-2"
    assert runtime.converse.call_args.kwargs["modelId"] == "test-model"
    assert "tools" not in runtime.converse.call_args.kwargs
    response_body["total_minor"] = 1
    runtime.converse.return_value["output"]["message"]["content"][0]["text"] = json.dumps(response_body)
    with pytest.raises(ValueError):
        bedrock_intent(IntentRequest(message="free tickets", current=current), Settings(bedrock_model="test-model"))


@pytest.mark.parametrize("token_auth", [False, True])
def test_surreal_mirror_excludes_session_and_access_preferences(monkeypatch, token_auth):
    from app.integrations import mirror_booking

    captured = {}
    class FakeDatabase:
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def signin(self, data): captured["auth_method"] = "password"
        async def authenticate(self, token): captured["auth_method"] = "token"
        async def use(self, *args): pass
        async def upsert(self, record, data): captured.update({"record": record, "data": data})
    monkeypatch.setitem(sys.modules, "surrealdb", SimpleNamespace(AsyncSurreal=lambda url: FakeDatabase()))
    monkeypatch.setenv("SURREAL_URL", "ws://localhost:9000")
    monkeypatch.setenv("SURREAL_USERNAME", "test")
    monkeypatch.setenv("SURREAL_PASSWORD", "test")
    if token_auth:
        monkeypatch.setenv("SURREAL_TOKEN", "test-only")
    result = asyncio.run(mirror_booking({"id": "FTH-123", "status": "demo_confirmed", "created_at": "2026-10-16", "quote": {"total_minor": 5000, "offer": {"category": "train"}, "preferences": {"captions": True}}, "session": "private"}))
    assert result == "mirrored"
    assert "preferences" not in str(captured)
    assert "session" not in str(captured)
    assert captured["auth_method"] == ("token" if token_auth else "password")


def test_anchor_uses_configured_page_and_step_limit(monkeypatch):
    from app.integrations import research_access
    captured = {}
    class FakeHTTP:
        def __init__(self, **kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def post(self, url, **kwargs):
            captured.update({"url": url, **kwargs})
            return httpx.Response(200, json={"data": {"result": "Unknown"}}, request=httpx.Request("POST", url))
    monkeypatch.setenv("ANCHOR_API_KEY", "test-only")
    monkeypatch.setattr("app.integrations.httpx.AsyncClient", FakeHTTP)
    result = asyncio.run(research_access("Are there captions?", "https://provider.example/access"))
    assert captured["url"] == "https://api.anchorbrowser.io/v1/tools/perform-web-task"
    assert captured["json"]["url"] == "https://provider.example/access"
    assert captured["json"]["max_steps"] == 8
    assert captured["json"]["human_intervention"] is False
    assert result["verified"] is False
    with pytest.raises(ValueError):
        asyncio.run(research_access("Try a file", "file:///private"))


def test_arize_ax_registers_http_tracing_without_console_or_auto_instrumentation(monkeypatch):
    from app.integrations import configure_tracing
    exporter = MagicMock()
    provider = MagicMock()
    resource = MagicMock()
    processor = MagicMock()
    monkeypatch.setitem(sys.modules, "opentelemetry.exporter.otlp.proto.http.trace_exporter", SimpleNamespace(OTLPSpanExporter=exporter))
    monkeypatch.setitem(sys.modules, "opentelemetry.sdk.resources", SimpleNamespace(Resource=resource))
    monkeypatch.setitem(sys.modules, "opentelemetry.sdk.trace", SimpleNamespace(TracerProvider=provider))
    monkeypatch.setitem(sys.modules, "opentelemetry.sdk.trace.export", SimpleNamespace(BatchSpanProcessor=processor))
    monkeypatch.setattr("app.integrations.trace.set_tracer_provider", MagicMock())
    monkeypatch.setenv("ARIZE_API_KEY", "test-key")
    monkeypatch.setenv("ARIZE_SPACE_ID", "test-space")
    monkeypatch.setenv("ARIZE_PROJECT_NAME", "faith-test")
    assert configure_tracing() is provider.return_value
    assert exporter.call_args.kwargs["endpoint"] == "https://otlp.arize.com/v1/traces"
    assert exporter.call_args.kwargs["headers"]["arize-space-id"] == "test-space"
    assert exporter.call_args.kwargs["headers"]["arize-api-key"] == "test-key"
    assert resource.create.call_args.args[0]["openinference.project.name"] == "faith-test"
    provider.return_value.add_span_processor.assert_called_once_with(processor.return_value)


def test_api_key_alone_does_not_enable_arize_tracing(monkeypatch):
    from app.integrations import configure_tracing
    monkeypatch.setenv("ARIZE_API_KEY", "test-key")
    assert configure_tracing() is None
