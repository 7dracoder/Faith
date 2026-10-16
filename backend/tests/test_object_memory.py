import base64
import hashlib
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.models import ObjectScanRequest
from app.object_vision import scan_objects

JPEG = b"\xff\xd8\xff\xe0synthetic-memory-frame\xff\xd9"
FRAME = base64.b64encode(JPEG).decode()
BOX = {"min_x": 0.2, "min_y": 0.3, "max_x": 0.5, "max_y": 0.7}
SCAN = {"objects": [{"label": "keys", "box": BOX, "confidence": 0.9, "place": "on the kitchen counter next to the kettle"},
                    {"label": "person", "box": BOX, "confidence": 0.95, "place": "standing"},
                    {"label": "blue mug", "box": BOX, "confidence": 0.3, "place": "on the desk"}]}


def now_iso(minutes_ago=0):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("BASETEN_API_KEY", "test-key")
    settings = Settings(database_path=str(tmp_path / "memory.sqlite3"), baseten_vision_model="vl-model")
    with TestClient(create_app(settings)) as client:
        token = client.post("/api/session").json()["session_token"]
        client.headers["Authorization"] = "Bearer " + token
        client.token = token
        yield client


def fake_scan(calls):
    def scan(body, settings):
        calls.append(body)
        from app.models import ObjectScanAnswer
        return ObjectScanAnswer.model_validate({"objects": SCAN["objects"][:1]})
    return scan


def test_scan_returns_objects_and_stores_nothing(client, surreal, monkeypatch):
    calls = []
    monkeypatch.setattr("app.main.scan_objects", fake_scan(calls))
    response = client.post("/api/objects/scan", json={"jpeg_base64": FRAME})
    assert response.status_code == 200
    assert response.json()["objects"][0]["label"] == "keys"
    assert len(calls) == 1
    # The scan itself writes nothing: no image, no labels.
    assert surreal.rows == {} and surreal.calls == []
    assert FRAME not in response.text


def test_scan_is_rate_limited_per_session(client, monkeypatch):
    monkeypatch.setattr("app.main.scan_objects", fake_scan([]))
    for _ in range(20):
        assert client.post("/api/objects/scan", json={"jpeg_base64": FRAME}).status_code == 200
    assert client.post("/api/objects/scan", json={"jpeg_base64": FRAME}).status_code == 429
    other = client.post("/api/objects/scan", json={"jpeg_base64": FRAME}, headers={"Authorization": "Bearer " + "o" * 43})
    assert other.status_code == 200


def test_scan_rejects_non_images_without_echo(client):
    response = client.post("/api/objects/scan", json={"jpeg_base64": base64.b64encode(b"a" * 40).decode()})
    assert response.status_code == 422
    assert client.post("/api/objects/scan", json={"jpeg_base64": FRAME, "store": True}).status_code == 422


def test_scan_failure_is_honest_and_hides_the_image(client, monkeypatch):
    def fail(*args):
        raise RuntimeError("private " + FRAME)
    monkeypatch.setattr("app.main.scan_objects", fail)
    response = client.post("/api/objects/scan", json={"jpeg_base64": FRAME})
    assert response.status_code == 502 and FRAME not in response.text


def test_scan_needs_baseten(tmp_path, monkeypatch):
    monkeypatch.delenv("BASETEN_API_KEY", raising=False)
    with TestClient(create_app(Settings(database_path=str(tmp_path / "x.sqlite3"), baseten_vision_model=""))) as client:
        client.headers["Authorization"] = "Bearer " + client.post("/api/session").json()["session_token"]
        assert client.post("/api/objects/scan", json={"jpeg_base64": FRAME}).status_code == 503
        assert client.get("/api/capabilities").json()["object_memory_configured"] is False


def test_scan_filters_people_and_low_confidence(monkeypatch):
    monkeypatch.setenv("BASETEN_API_KEY", "test-key")
    reply = MagicMock()
    reply.json.return_value = {"choices": [{"message": {"content": "```json\n" + json.dumps(SCAN) + "\n```"}}]}
    post = MagicMock(return_value=reply)
    monkeypatch.setattr("httpx.post", post)
    result = scan_objects(ObjectScanRequest(jpeg_base64=FRAME), Settings(baseten_vision_model="vl-model"))
    assert [(o.label, o.place) for o in result.objects] == [("keys", "on the kitchen counter next to the kettle")]
    request = post.call_args.kwargs["json"]
    assert request["chat_template_kwargs"] == {"thinking": False}
    assert request["messages"][1]["content"][0]["image_url"]["url"] == "data:image/jpeg;base64," + FRAME


def test_memory_keeps_only_labels_places_times_positions_under_a_hashed_session(client, surreal):
    entry = {"label": "keys", "place": "on the kitchen counter", "seen_at": now_iso(3),
             "position": [0.1, -0.2, -0.5], "ar_session": "123e4567-e89b-12d3-a456-426614174000"}
    stored = client.post("/api/objects/memory", json={"entries": [entry]})
    assert stored.status_code == 200
    record = "object_memory:" + hashlib.sha256(client.token.encode()).hexdigest()
    assert list(surreal.rows) == [record]
    assert client.token not in repr(surreal.rows) and client.token not in repr(surreal.calls)
    saved = surreal.rows[record]["items"]["key"]
    assert set(saved) == {"label", "place", "seen_at", "position", "ar_session"}

    found = client.get("/api/objects/memory", params={"name": "where are my key"}).json()["objects"]
    assert [item["label"] for item in found] == ["keys"]
    assert client.get("/api/objects/memory", params={"name": "wallet"}).json()["objects"] == []

    assert client.delete("/api/objects/memory").json() == {"forgotten": True}
    assert client.get("/api/objects/memory", params={"name": "keys"}).json()["objects"] == []


def test_memory_keeps_the_newest_sighting_per_object_and_is_per_session(client, surreal):
    client.post("/api/objects/memory", json={"entries": [{"label": "keys", "place": "on the desk", "seen_at": now_iso(10)}]})
    client.post("/api/objects/memory", json={"entries": [{"label": "Keys", "place": "by the door", "seen_at": now_iso(1)}]})
    client.post("/api/objects/memory", json={"entries": [{"label": "keys", "place": "in the bin", "seen_at": now_iso(30)}]})
    assert [item["place"] for item in client.get("/api/objects/memory").json()["objects"]] == ["by the door"]
    other = client.get("/api/objects/memory", headers={"Authorization": "Bearer " + "o" * 43})
    assert other.json()["objects"] == []


@pytest.mark.parametrize("entry", [
    {"label": "keys", "seen_at": now_iso(), "jpeg_base64": FRAME},
    {"label": "keys", "seen_at": now_iso(), "utterance": "where are my keys"},
    {"label": "<script>", "seen_at": now_iso()},
    {"label": "keys", "seen_at": now_iso(60 * 24 * 8)},
    {"label": "keys", "seen_at": now_iso(), "position": [1e9, 0, 0]},
])
def test_memory_rejects_pictures_words_and_bad_values(client, surreal, entry):
    assert client.post("/api/objects/memory", json={"entries": [entry]}).status_code == 422
    assert surreal.rows == {}


def test_memory_reads_empty_before_the_table_exists(client, surreal, monkeypatch):
    async def missing_table(self, record):
        return "The table 'object_memory' does not exist"
    monkeypatch.setattr(surreal, "select", missing_table)
    assert client.get("/api/objects/memory", params={"name": "keys"}).json() == {"objects": []}


def test_memory_disabled_without_surreal(client):
    assert client.get("/api/objects/memory").status_code == 503
    assert client.delete("/api/objects/memory").status_code == 503
