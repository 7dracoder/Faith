import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "agent.sqlite3")))) as client:
        client.post("/api/session")
        client.headers["X-Faith-Client"] = "web"
        yield client


def test_agent_unconfigured_is_honest(client):
    response = client.post("/api/agent/session")
    assert response.status_code == 503
    assert client.get("/api/capabilities").json()["agent_configured"] is False


def test_agent_session_needs_session_and_write_header(client, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key"); monkeypatch.setenv("ELEVENLABS_AGENT_ID", "agent_1")
    client.headers.pop("X-Faith-Client")
    assert client.post("/api/agent/session").status_code == 403
    client.cookies.clear()
    assert client.post("/api/agent/session").status_code == 401


def test_agent_session_returns_short_lived_token_only_and_is_limited(client, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key"); monkeypatch.setenv("ELEVENLABS_AGENT_ID", "agent_1")
    async def fake(): return "conversation-jwt"
    monkeypatch.setattr("app.main.conversation_token", fake)
    for _ in range(10):
        response = client.post("/api/agent/session")
        assert response.status_code == 200
        assert response.json()["conversation_token"] == "conversation-jwt"
        assert "test-key" not in response.text
        assert response.headers["cache-control"] == "no-store"
    assert client.post("/api/agent/session").status_code == 429


def test_agent_failure_hides_provider_details(client, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key"); monkeypatch.setenv("ELEVENLABS_AGENT_ID", "agent_1")
    async def fail(): raise RuntimeError("upstream said test-key is bad")
    monkeypatch.setattr("app.main.conversation_token", fail)
    response = client.post("/api/agent/session")
    assert response.status_code == 502
    assert "test-key" not in response.text
