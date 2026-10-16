from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.integrations import REAL_SOURCES, real_times_prompt
from app.main import create_app

TOMORROW = (date.today() + timedelta(days=1)).isoformat()


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "real.sqlite3")))) as client:
        client.post("/api/session")
        client.headers["X-Faith-Client"] = "web"
        yield client


def fake_times(calls, status="success", text="- **9:05 AM**, 3h 40m, from $39."):
    async def lookup(category, origin, destination, day):
        calls.append((category, origin, destination, day))
        return {"status": status, "result": text}
    return lookup


def body(**overrides):
    return {"category": "train", "origin": "New York", "destination": "Boston", "date": TOMORROW, **overrides}


def test_disabled_without_anchor(client):
    assert client.post("/api/real-search", json=body()).status_code == 503
    assert client.get("/api/capabilities").json()["real_times_configured"] is False


def test_flights_and_events_are_declined(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    for category in ["flight", "event"]:
        response = client.post("/api/real-search", json=body(category=category))
        assert response.status_code == 422 and "trains, buses, and cinemas" in response.json()["detail"]


def test_rejects_urls_and_bad_input(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    for invalid in [body(url="https://evil.example"), body(origin="https://evil.example"), body(destination="<b>"),
                    body(date="2000-01-01"), body(category="ferry")]:
        assert client.post("/api/real-search", json=invalid).status_code == 422


def test_uses_fixed_site_caches_and_is_unverified(client, monkeypatch):
    calls = []
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.real_times", fake_times(calls))
    first = client.post("/api/real-search", json=body()).json()
    assert first["provider"] == "Amtrak" and first["source"] == REAL_SOURCES["train"][1]
    assert first["verified"] is False and first["cached"] is False
    assert "**" not in first["summary"] and "demo tickets" in first["notice"]
    second = client.post("/api/real-search", json=body(origin="new york", destination="BOSTON")).json()
    assert second["cached"] is True and len(calls) == 1


def test_rate_limited_per_session(client, monkeypatch):
    calls = []
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.real_times", fake_times(calls))
    statuses = [client.post("/api/real-search", json=body(destination=city)).status_code
                for city in ["Boston", "Albany", "Philadelphia", "Baltimore"]]
    assert statuses == [200, 200, 200, 429]


def test_failure_says_nothing_was_booked(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.real_times", fake_times([], status="failure"))
    response = client.post("/api/real-search", json=body(category="bus"))
    assert response.status_code == 502 and "Nothing was booked" in response.json()["detail"]


def test_prompt_is_read_only():
    prompt = real_times_prompt("cinema", "Chicago", "Dune", TOMORROW)
    assert "Do not log in" in prompt and "purchase" in prompt and "Stop at the results list" in prompt
    assert "Chicago" in prompt and "Dune" in prompt
