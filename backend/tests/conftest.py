import sys
import types

import pytest


@pytest.fixture(autouse=True)
def disable_external_services(monkeypatch):
    """Local credentials must never turn synthetic unit tests into cloud calls."""
    for key in ["ARIZE_SPACE_ID", "PHOENIX_COLLECTOR_ENDPOINT", "SURREAL_URL", "SURREAL_TOKEN", "ANCHOR_API_KEY", "ELEVENLABS_API_KEY", "ELEVENLABS_AGENT_ID", "BASETEN_API_KEY"]:
        monkeypatch.delenv(key, raising=False)


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
