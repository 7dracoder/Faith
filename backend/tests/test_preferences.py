import hashlib
import sys
import types
import pytest
from fastapi.testclient import TestClient

from app import integrations
from app.config import Settings
from app.main import create_app


class FakeSurreal:
    """Stands in for surrealdb.AsyncSurreal; records every call."""
    rows, calls = {}, []

    def __init__(self, url):
        self.url = url

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def signin(self, credentials):
        FakeSurreal.calls.append(("signin", credentials["namespace"], credentials["database"]))

    async def use(self, namespace, database):
        pass

    async def upsert(self, record, data):
        FakeSurreal.calls.append(("upsert", str(record), data))
        FakeSurreal.rows[str(record)] = data

    async def select(self, record):
        # Like the real SDK, selecting one record returns a list.
        return [FakeSurreal.rows[str(record)]] if str(record) in FakeSurreal.rows else []

    async def delete(self, record):
        FakeSurreal.calls.append(("delete", str(record)))
        FakeSurreal.rows.pop(str(record), None)


class FakeRecordID:
    def __init__(self, table, key):
        self.table, self.key = table, key

    def __str__(self):
        return f"{self.table}:{self.key}"


@pytest.fixture
def surreal(monkeypatch):
    # A stand-in module, so these tests run without the optional surrealdb package.
    FakeSurreal.rows, FakeSurreal.calls = {}, []
    monkeypatch.setitem(sys.modules, "surrealdb", types.SimpleNamespace(AsyncSurreal=FakeSurreal, RecordID=FakeRecordID))
    for key, value in {"SURREAL_URL": "wss://example.invalid/rpc", "SURREAL_USERNAME": "test_user", "SURREAL_PASSWORD": "pw"}.items():
        monkeypatch.setenv(key, value)
    return FakeSurreal


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "prefs.sqlite3")))) as client:
        token = client.post("/api/session").json()["session_token"]
        client.headers["Authorization"] = "Bearer " + token
        client.token = token
        yield client


def test_preferences_disabled_without_surreal(client):
    assert client.get("/api/preferences").status_code == 503
    assert client.put("/api/preferences", json={"home_city": "Boston"}).status_code == 503
    assert client.get("/api/capabilities").json()["preferences_configured"] is False


def test_save_read_and_forget_use_a_hashed_session(client, surreal):
    body = {"home_city": "Boston", "step_free": True, "companion": True, "passengers": 2}
    saved = client.put("/api/preferences", json=body)
    assert saved.status_code == 200
    assert saved.json()["summary"] == "home city Boston; usually 2 people; needs step-free access, a companion seat"
    record = "preference:" + hashlib.sha256(client.token.encode()).hexdigest()
    assert list(surreal.rows) == [record]
    assert ("signin", "faith", "booking") in surreal.calls
    # The raw session token is never stored or used as a key.
    assert client.token not in repr(surreal.calls) and client.token not in repr(surreal.rows)

    read = client.get("/api/preferences").json()
    assert read["preferences"] == {"home_city": "Boston", "step_free": True, "audio_description": False, "companion": True, "passengers": 2}

    assert client.delete("/api/preferences").json() == {"forgotten": True}
    assert client.get("/api/preferences").json() == {"preferences": None, "summary": "none"}


def test_preferences_are_per_session(client, surreal):
    client.put("/api/preferences", json={"home_city": "Boston"})
    other = "o" * 43
    response = client.get("/api/preferences", headers={"Authorization": "Bearer " + other})
    assert response.json()["preferences"] is None


def test_preferences_reject_unknown_or_location_fields(client, surreal):
    for invalid in [{"location": "40.7,-74.0"}, {"objects": ["keys"]}, {"home_city": "<script>"}, {"passengers": 9}]:
        assert client.put("/api/preferences", json=invalid).status_code == 422
    assert surreal.rows == {}


def test_storage_failure_is_honest(client, surreal, monkeypatch):
    async def broken(*args):
        raise RuntimeError("secret detail")
    monkeypatch.setattr("app.main.save_preferences", broken)
    response = client.put("/api/preferences", json={"home_city": "Boston"})
    assert response.status_code == 502 and "secret" not in response.text


def test_agent_session_passes_saved_preferences(client, surreal, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    monkeypatch.setenv("ELEVENLABS_AGENT_ID", "agent")

    async def token():
        return "conv-token"
    monkeypatch.setattr("app.main.conversation_token", token)
    assert client.post("/api/agent/session").json()["saved_preferences"] == "none"
    client.put("/api/preferences", json={"audio_description": True})
    assert client.post("/api/agent/session").json()["saved_preferences"] == "needs audio description"


def test_describe_preferences_handles_empty():
    assert integrations.describe_preferences(None) == "none"
    assert integrations.describe_preferences({"step_free": False}) == "none"
