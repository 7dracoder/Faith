import asyncio
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.integrations import create_speech
from app.main import create_app


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "speech.sqlite3")))) as client:
        client.post("/api/session")
        client.headers["X-Faith-Client"] = "web"
        yield client


def test_speech_requires_session_write_header_and_explicit_consent(client):
    body = {"text": "Please show me the platform.", "consent": True}
    client.headers.pop("X-Faith-Client")
    assert client.post("/api/speech", json=body).status_code == 403
    client.cookies.clear()
    assert client.post("/api/speech", json=body).status_code == 401
    client.post("/api/session")
    client.headers["X-Faith-Client"] = "web"
    for invalid in [{"text": "Hello"}, {"text": "Hello", "consent": False}, {"text": " " * 5, "consent": True}, {"text": "x" * 601, "consent": True}, {**body, "voice_id": "unapproved"}]:
        assert client.post("/api/speech", json=invalid).status_code == 422


def test_speech_disabled_has_visible_fallback_and_no_secret(client):
    response = client.post("/api/speech", json={"text": "Hello", "consent": True})
    assert response.status_code == 503
    assert "device read-aloud" in response.json()["detail"]
    assert client.get("/api/capabilities").json()["elevenlabs_configured"] is False


def test_speech_returns_private_audio_and_rate_limits_paid_calls(client, monkeypatch):
    calls = []
    async def fake(text):
        calls.append(text)
        return b"ID3-test-audio"
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.setattr("app.main.create_speech", fake)
    for _ in range(4):
        response = client.post("/api/speech", json={"text": "Hello", "consent": True})
        assert response.status_code == 200
        assert response.headers["content-type"] == "audio/mpeg"
        assert response.headers["cache-control"] == "no-store"
        assert response.content == b"ID3-test-audio"
    assert client.post("/api/speech", json={"text": "Hello", "consent": True}).status_code == 429
    assert calls == ["Hello"] * 4
    assert client.get("/api/bookings").json()["bookings"] == []


def test_speech_provider_failure_is_sanitized_and_not_retried(client, monkeypatch):
    calls = []
    async def failed(text):
        calls.append(text)
        raise RuntimeError("secret provider body test-key")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.setattr("app.main.create_speech", failed)
    response = client.post("/api/speech", json={"text": "Hello", "consent": True})
    assert response.status_code == 502
    assert "test-key" not in response.text
    assert "text is still available" in response.text
    assert calls == ["Hello"]


def test_speech_global_character_budget_survives_new_anonymous_sessions(client, monkeypatch):
    async def fake(text): return b"ID3-audio"
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.setattr("app.main.create_speech", fake)
    for _ in range(16):
        client.cookies.clear()
        client.post("/api/session")
        assert client.post("/api/speech", json={"text": "x" * 600, "consent": True}).status_code == 200
    client.cookies.clear()
    client.post("/api/session")
    assert client.post("/api/speech", json={"text": "x" * 600, "consent": True}).status_code == 429


@pytest.mark.parametrize("content_type,content,success", [("audio/mpeg", b"ID3-audio", True), ("application/json", b"{}", False), ("audio/mpeg", b"", False), ("audio/mpeg", b"x" * 2_000_001, False)])
def test_elevenlabs_contract_and_bounded_audio(monkeypatch, content_type, content, success):
    actual_client = httpx.AsyncClient
    def handle(request):
        assert str(request.url) == "https://api.elevenlabs.io/v1/text-to-speech/TestVoice?output_format=mp3_44100_128"
        assert request.headers["xi-api-key"] == "test-key"
        assert json.loads(request.content) == {"text": "Hello", "model_id": "eleven_multilingual_v2"}
        return httpx.Response(200, headers={"content-type": content_type}, content=content)
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.setenv("ELEVENLABS_VOICE_ID", "TestVoice")
    monkeypatch.setenv("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2")
    monkeypatch.setattr("app.integrations.httpx.AsyncClient", lambda **kwargs: actual_client(transport=httpx.MockTransport(handle), **kwargs))
    if success:
        assert asyncio.run(create_speech("Hello")) == content
    else:
        with pytest.raises(ValueError):
            asyncio.run(create_speech("Hello"))
