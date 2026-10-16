import asyncio
import hashlib
import json
from datetime import date, timedelta
from urllib.parse import urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from app import integrations
from app.config import Settings
from app.integrations import LIVE_SOURCES, live_options, live_prompt, live_search
from app.main import create_app

TOMORROW = (date.today() + timedelta(days=1)).isoformat()
OPTIONS = [{"what": "JetBlue, nonstop, JFK to BOS", "departs": "1:00 PM", "arrives": "2:29 PM", "duration": "1h 29m", "price": "$144"},
           {"what": "Delta, nonstop, LGA to BOS", "departs": "6:00 AM", "arrives": "7:15 AM", "duration": "1h 15m", "price": "$214"}]


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "real.sqlite3")))) as client:
        token = client.post("/api/session").json()["session_token"]
        client.headers["Authorization"] = "Bearer " + token
        client.token = token
        yield client


def fake_search(calls, found=("Google Flights", "https://www.google.com/travel/flights?q=x", OPTIONS)):
    async def search(category, origin, destination, day):
        calls.append((category, origin, destination, day))
        return found
    return search


def body(**overrides):
    return {"category": "flight", "origin": "New York", "destination": "Boston", "date": TOMORROW, **overrides}


def test_disabled_without_anchor(client):
    assert client.post("/api/real-search", json=body()).status_code == 503
    assert client.get("/api/capabilities").json()["real_times_configured"] is False


def test_every_kind_of_ticket_is_searched(client, monkeypatch):
    calls = []
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.live_search", fake_search(calls))
    for category in ["flight", "train", "bus", "cinema", "event"]:
        # A fresh session each time: three live searches per session per ten minutes.
        client.cookies.clear()
        client.headers["Authorization"] = "Bearer " + client.post("/api/session").json()["session_token"]
        assert client.post("/api/real-search", json=body(category=category)).status_code == 200
    assert [call[0] for call in calls] == ["flight", "train", "bus", "cinema", "event"]


def test_travel_needs_a_destination(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.live_search", fake_search([]))
    for category in ["flight", "train", "bus"]:
        assert client.post("/api/real-search", json=body(category=category, destination="")).status_code == 422
    assert client.post("/api/real-search", json=body(category="event", destination="")).status_code == 200


def test_rejects_urls_and_bad_input(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    for invalid in [body(url="https://evil.example"), body(origin="https://evil.example"), body(destination="<b>"),
                    body(destination="Boston/../evil"), body(date="2000-01-01"), body(category="ferry")]:
        assert client.post("/api/real-search", json=invalid).status_code == 422


def test_returns_options_with_ids_caches_and_is_honest(client, monkeypatch):
    calls = []
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.live_search", fake_search(calls))
    first = client.post("/api/real-search", json=body()).json()
    assert first["provider"] == "Google Flights" and first["verified"] is False and first["cached"] is False
    assert [o["what"] for o in first["options"]] == [o["what"] for o in OPTIONS]
    assert all(o["option_id"].startswith("live-") and o["provider"] == "Google Flights" for o in first["options"])
    assert "can't pay" in first["notice"] and "demo" not in first["notice"].lower()
    second = client.post("/api/real-search", json=body(origin="new york", destination="BOSTON")).json()
    assert second["cached"] is True and len(calls) == 1


def test_rate_limited_per_session(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.live_search", fake_search([]))
    statuses = [client.post("/api/real-search", json=body(destination=city)).status_code
                for city in ["Boston", "Albany", "Philadelphia", "Baltimore"]]
    assert statuses == [200, 200, 200, 429]


def test_failure_says_nothing_was_booked(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.live_search", fake_search([], found=None))
    response = client.post("/api/real-search", json=body(category="bus"))
    assert response.status_code == 502 and "Couldn't get live times" in response.json()["detail"]


def test_sources_are_fixed_hosts_with_places_only_in_path_or_query():
    for category, sources in LIVE_SOURCES.items():
        for provider, host, build in sources:
            link = build("New York", "Boston", TOMORROW)
            parsed = urlparse(link)
            assert parsed.scheme == "https" and parsed.hostname == host and not parsed.username, (category, provider)


def test_options_are_cleaned_and_prices_must_be_amounts():
    raw = {"options": [{"what": "Clayface <b>AMC</b>", "departs": "10:00a", "price": "UP TO 15% OFF"},
                       {"what": "No time", "departs": "", "price": "$9"},
                       {"what": "Free show", "departs": "Sat 2 PM", "price": "Free"}] + [OPTIONS[0]] * 6}
    options = live_options({"result": json.dumps(raw)})
    assert len(options) == 5
    assert options[0] == {"what": "Clayface bAMC/b", "departs": "10:00a", "arrives": None, "duration": None, "price": None}
    assert options[1]["price"] == "Free" and "No time" not in [o["what"] for o in options]
    assert live_options({"result": "not json"}) == [] and live_options({"result": {"options": "x"}}) == []


def test_live_search_falls_back_to_the_next_provider(monkeypatch):
    tried = []

    async def anchor(url, prompt, max_steps, timeout, output_schema=None):
        tried.append(urlparse(url).hostname)
        assert output_schema and "purchase" in prompt
        if "greyhound" in url:
            return {"status": "success", "result": json.dumps({"options": []})}
        return {"status": "success", "result": json.dumps({"options": OPTIONS})}

    monkeypatch.setattr(integrations, "anchor_task", anchor)
    provider, link, options = asyncio.run(live_search("bus", "New York", "Boston", TOMORROW))
    assert tried == ["www.greyhound.com", "www.wanderu.com"] and provider == "Wanderu" and len(options) == 2
    assert link.startswith("https://www.wanderu.com/")


def test_live_search_reports_nothing_when_every_provider_fails(monkeypatch):
    async def anchor(url, prompt, max_steps, timeout, output_schema=None):
        raise httpx.ConnectError("blocked")

    monkeypatch.setattr(integrations, "anchor_task", anchor)
    assert asyncio.run(live_search("bus", "New York", "Boston", TOMORROW)) is None


def test_anchor_task_closes_its_browser(monkeypatch):
    requests = []
    session = "5fe6decf-0e54-4108-873f-1a39daec7488"

    def handler(request):
        requests.append((request.method, request.url.path))
        if request.method == "POST":
            return httpx.Response(200, json={"status": "success", "result": "{}", "sessionId": session})
        return httpx.Response(200, json={"data": {"status": "success"}})

    real_client = httpx.AsyncClient
    monkeypatch.setattr(integrations.httpx, "AsyncClient",
                        lambda **kwargs: real_client(transport=httpx.MockTransport(handler), **kwargs))
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    asyncio.run(integrations.anchor_task("https://www.wanderu.com/", "p", 5, 10))
    assert requests == [("POST", "/v1/tools/perform-web-task"), ("DELETE", f"/v1/sessions/{session}")]


def test_prompt_is_read_only():
    prompt = live_prompt("cinema", "Chicago", "Dune", TOMORROW)
    assert "Do not log in" in prompt and "purchase" in prompt and "Stop at the results list" in prompt
    assert "Chicago" in prompt and "Dune" in prompt and "Never invent" in prompt


def chosen(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_API_KEY", "k")
    monkeypatch.setattr("app.main.live_search", fake_search([]))
    return client.post("/api/real-search", json=body()).json()["options"][0]


def test_saving_a_trip_keeps_the_choice_and_link_under_a_hashed_session(client, surreal, monkeypatch):
    option = chosen(client, monkeypatch)
    reply = client.post("/api/trips", json={"option_id": option["option_id"]})
    assert reply.status_code == 201
    saved = reply.json()
    assert saved["paid"] is False and "can't pay for tickets" in saved["say"] and "provider link" in saved["say"]
    record = "trip:" + hashlib.sha256(client.token.encode()).hexdigest()
    assert list(surreal.rows) == [record] and client.token not in repr(surreal.rows)
    trip = surreal.rows[record]["trips"][0]
    assert trip["what"] == OPTIONS[0]["what"] and trip["link"].startswith("https://www.google.com/")
    assert set(trip) == {"what", "departs", "arrives", "duration", "price", "provider", "link", "category", "date",
                         "origin", "destination", "saved_at"}
    assert client.get("/api/trips").json()["trips"][0]["what"] == OPTIONS[0]["what"]


def test_only_options_from_this_sessions_search_can_be_saved(client, surreal, monkeypatch):
    chosen(client, monkeypatch)
    assert client.post("/api/trips", json={"option_id": "live-00000000"}).status_code == 404
    assert client.post("/api/trips", json={"option_id": "https://evil.example"}).status_code == 422
    assert surreal.rows == {}


def test_trips_need_surreal(client, monkeypatch):
    option = chosen(client, monkeypatch)
    response = client.post("/api/trips", json={"option_id": option["option_id"]})
    assert response.status_code == 503 and "nothing was saved" in response.json()["detail"]


def test_eventbrite_lists_known_cities_under_their_state():
    assert integrations.eventbrite_link("New York") == "https://www.eventbrite.com/d/ny--new-york/events/"
    assert integrations.eventbrite_link("Smalltown") == "https://www.eventbrite.com/"
