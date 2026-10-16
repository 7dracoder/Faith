import json
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.models import ConfirmRequest


@pytest.fixture
def app(tmp_path, monkeypatch):
    for key in ["PHOENIX_COLLECTOR_ENDPOINT", "SURREAL_URL", "ANCHOR_API_KEY"]:
        monkeypatch.delenv(key, raising=False)
    return create_app(Settings(database_path=str(tmp_path / "test.sqlite3"), ai_provider="local"))


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        test_client.post("/api/session")
        test_client.headers["X-Faith-Client"] = "web"
        yield test_client


def search_body(**updates):
    body = {"category": "all", "origin": "New York", "destination": "Boston",
            "date": str(date.today() + timedelta(days=7)), "passengers": 2, "preferences": {"text_updates": True}}
    return {**body, **updates}


def get_quote(client, **search_updates):
    response = client.post("/api/search", json=search_body(**search_updates))
    assert response.status_code == 200, response.text
    offer = response.json()["offers"][0]
    response = client.post("/api/quotes", json={"offer_id": offer["id"], "passengers": 2, "preferences": {"text_updates": True}})
    assert response.status_code == 201, response.text
    return offer, response.json()


def confirm_body(quote, key="confirm_1234567890123456"):
    return {"quote_id": quote["id"], "accepted_demo": True, "idempotency_key": key}


def test_all_categories_and_demo_disclosures(client):
    response = client.post("/api/search", json=search_body())
    offers = response.json()["offers"]
    assert {offer["category"] for offer in offers} == {"flight", "train", "bus", "cinema", "event"}
    assert all(offer["demo"] for offer in offers)
    assert all("verified" in offer["access_note"] for offer in offers)


@pytest.mark.parametrize("category", ["flight", "train", "bus", "cinema", "event"])
def test_each_category_can_complete_booking(client, category):
    _, quote = get_quote(client, category=category)
    ticket = client.post("/api/bookings", json=confirm_body(quote)).json()
    assert ticket["status"] == "demo_confirmed"
    assert ticket["quote"]["offer"]["category"] == category
    assert ticket["admission_valid"] is False
    assert ticket["demo"] is True


def test_access_filters_require_every_requested_feature(client):
    response = client.post("/api/search", json=search_body(preferences={"captions": True, "audio_description": True}))
    assert response.json()["offers"]
    for offer in response.json()["offers"]:
        assert {"captions", "audio_description"}.issubset(offer["features"])


def test_budget_is_whole_group_including_fees(client):
    response = client.post("/api/search", json=search_body(max_price=5200))
    assert response.json()["offers"]
    assert all((offer["price_minor"] + offer["fee_minor"]) * 2 <= 5200 for offer in response.json()["offers"])


def test_no_results_is_success_not_provider_failure(client):
    response = client.post("/api/search", json=search_body(category="flight", preferences={"captions": True}))
    assert response.status_code == 200
    assert response.json()["offers"] == []


def test_quote_is_authoritative_and_rejects_client_price(client):
    offer, quote = get_quote(client)
    assert quote["total_minor"] == 2 * (offer["price_minor"] + offer["fee_minor"])
    assert quote["total_minor"] == quote["subtotal_minor"] + quote["fees_minor"]
    response = client.post("/api/quotes", json={"offer_id": offer["id"], "passengers": 2, "preferences": {}, "price_minor": 1})
    assert response.status_code == 422


def test_confirmation_requires_explicit_acknowledgement(client):
    _, quote = get_quote(client)
    body = confirm_body(quote)
    body["accepted_demo"] = False
    assert client.post("/api/bookings", json=body).status_code == 422


def test_expired_review_cannot_create_ticket(client, app):
    _, quote = get_quote(client)
    expired = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    app.state.store.db.execute("UPDATE quotes SET expires=? WHERE id=?", (expired, quote["id"]))
    app.state.store.db.commit()
    assert client.post("/api/bookings", json=confirm_body(quote)).status_code == 410
    assert client.get("/api/bookings").json()["bookings"] == []


def test_confirmation_retries_and_double_taps_make_one_ticket(client):
    _, quote = get_quote(client)
    first = client.post("/api/bookings", json=confirm_body(quote)).json()
    repeated = client.post("/api/bookings", json=confirm_body(quote)).json()
    another_key = client.post("/api/bookings", json=confirm_body(quote, "another_confirm_1234567890")).json()
    assert first["id"] == repeated["id"] == another_key["id"]
    assert len(client.get("/api/bookings").json()["bookings"]) == 1


def test_parallel_confirmation_is_atomic(client, app):
    _, quote = get_quote(client)
    owner = client.cookies.get("faith_session")
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda i: app.state.store.confirm(owner, ConfirmRequest(**confirm_body(quote, f"parallel_key_{i:016d}"))), range(8)))
    assert len({ticket["id"] for ticket in results}) == 1


def test_key_reuse_for_other_quote_is_rejected(client):
    _, first = get_quote(client)
    _, second = get_quote(client)
    client.post("/api/bookings", json=confirm_body(first))
    assert client.post("/api/bookings", json=confirm_body(second)).status_code == 409


def test_other_session_cannot_read_quote_or_cancel_ticket(client, app):
    offer, quote = get_quote(client)
    ticket = client.post("/api/bookings", json=confirm_body(quote)).json()
    other = TestClient(app)
    other.post("/api/session")
    other.headers["X-Faith-Client"] = "web"
    assert other.get("/api/bookings").json()["bookings"] == []
    assert other.post("/api/bookings", json=confirm_body(quote)).status_code == 404
    assert other.post(f"/api/bookings/{ticket['id']}/cancel").status_code == 404
    assert other.post("/api/quotes", json={"offer_id": offer["id"], "passengers": 1, "preferences": {}}).status_code == 404
    other.close()


def test_native_bearer_session_and_cookie_csrf_protection(client):
    token = client.cookies.get("faith_session")
    client.headers.pop("X-Faith-Client")
    assert client.post("/api/search", json=search_body()).status_code == 403
    assert client.post("/api/search", json=search_body(), headers={"Authorization": "Bearer " + token}).status_code == 200


def test_cancel_is_idempotent_and_confirmation_retry_never_reactivates(client):
    _, quote = get_quote(client)
    ticket = client.post("/api/bookings", json=confirm_body(quote)).json()
    for _ in range(2):
        assert client.post(f"/api/bookings/{ticket['id']}/cancel").json()["status"] == "demo_cancelled"
    assert client.post("/api/bookings", json=confirm_body(quote)).json()["status"] == "demo_cancelled"


def test_session_and_booking_survive_server_restart(tmp_path, monkeypatch):
    monkeypatch.delenv("PHOENIX_COLLECTOR_ENDPOINT", raising=False)
    settings = Settings(database_path=str(tmp_path / "persist.sqlite3"), ai_provider="local")
    with TestClient(create_app(settings)) as first:
        token = first.post("/api/session").json()["session_token"]
        first.headers["Authorization"] = "Bearer " + token
        _, quote = get_quote(first)
        first.post("/api/bookings", json=confirm_body(quote))
    with TestClient(create_app(settings)) as second:
        response = second.get("/api/bookings", headers={"Authorization": "Bearer " + token})
        assert len(response.json()["bookings"]) == 1


def test_intent_parses_group_route_date_budget_and_access(client):
    response = client.post("/api/assistant", json={"message": "Two train tickets from New York to Boston tomorrow under $150 with step-free access", "current": search_body(passengers=1)})
    assert response.status_code == 200
    result = response.json()["search"]
    assert result["category"] == "train"
    assert result["passengers"] == 2
    assert result["destination"] == "Boston"
    assert result["max_price"] == 15000
    assert result["preferences"]["step_free"] is True
    assert result["date"] == str(date.today() + timedelta(days=1))


def test_bedrock_error_falls_back_without_exposing_exception(client, monkeypatch):
    import app.main as main
    monkeypatch.setattr(main, "bedrock_intent", lambda *args: (_ for _ in ()).throw(RuntimeError("sensitive upstream body")))
    # Build a distinct app with Bedrock selected so the adapter is actually exercised.
    with TestClient(create_app(Settings(database_path=":memory:", ai_provider="bedrock"))) as remote:
        token = remote.post("/api/session").json()["session_token"]
        response = remote.post("/api/assistant", headers={"Authorization": "Bearer " + token}, json={"message": "cinema with captions", "current": search_body()})
        assert response.status_code == 200
        assert response.json()["provider"] == "local_fallback"
        assert "sensitive" not in response.text


@pytest.mark.parametrize("updates", [{"passengers": 0}, {"passengers": 7}, {"category": "unknown"}, {"max_price": -1}, {"date": "2000-01-01"}])
def test_invalid_search_is_rejected(client, updates):
    assert client.post("/api/search", json=search_body(**updates)).status_code == 422


def test_security_headers(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
    assert client.get("/api/bookings").headers["cache-control"] == "no-store"


def test_research_requires_operator_configuration_and_authority(client):
    response = client.post("/api/research", json={"question": "Is step-free access documented?"})
    assert response.status_code == 403


def test_no_authenticated_booking_without_session(app):
    visitor = TestClient(app)
    assert visitor.get("/api/bookings").status_code == 401
    assert visitor.post("/api/search", json=search_body()).status_code == 401
    visitor.close()
