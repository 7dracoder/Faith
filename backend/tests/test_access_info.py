import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.integrations import ACCESS_SOURCES
from app.main import create_app


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "access.sqlite3")))) as client:
        client.post("/api/session")
        client.headers["X-Faith-Client"] = "web"
        yield client


def fake_research(calls, status="success", text="- **Captions**: ask staff."):
    async def research(question, url):
        calls.append((question, url))
        return {"source": url, "result": {"status": status, "result": text}, "verified": False}
    return research


def test_access_info_disabled_without_anchor_key(client):
    response = client.post("/api/access-info", json={"category": "train"})
    assert response.status_code == 503
    assert client.get("/api/capabilities").json()["access_info_configured"] is False


def test_access_info_rejects_user_urls_and_unknown_categories(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "test-key")
    for invalid in [{"category": "all"}, {"category": "train", "url": "https://evil.example"}, {"category": "ferry"}]:
        assert client.post("/api/access-info", json=invalid).status_code == 422


def test_access_info_uses_fixed_source_caches_and_is_unverified(client, monkeypatch):
    calls = []
    monkeypatch.setenv("ANCHOR_API_KEY", "test-key")
    monkeypatch.setattr("app.main.research_access", fake_research(calls))
    body = {"category": "cinema", "preferences": {"captions": True}}
    first = client.post("/api/access-info", json=body).json()
    second = client.post("/api/access-info", json=body).json()
    assert len(calls) == 1 and calls[0][1] == ACCESS_SOURCES["cinema"][1]
    assert "captions" in calls[0][0] and "deaf" in calls[0][0]
    assert first["summary"] == "- Captions: ask staff." and first["verified"] is False and first["cached"] is False
    assert second["cached"] is True and "Confirm with AMC Theatres" in second["notice"]


def test_access_info_failure_and_rate_limit(client, monkeypatch):
    calls = []
    monkeypatch.setenv("ANCHOR_API_KEY", "test-key")
    monkeypatch.setattr("app.main.research_access", fake_research(calls, status="failed", text=""))
    assert client.post("/api/access-info", json={"category": "bus"}).status_code == 502
    assert client.post("/api/access-info", json={"category": "bus"}).status_code == 502
    assert client.post("/api/access-info", json={"category": "bus"}).status_code == 502
    assert client.post("/api/access-info", json={"category": "bus"}).status_code == 429
    assert len(calls) == 3
