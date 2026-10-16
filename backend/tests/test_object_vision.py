import base64
import json
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.models import ObjectBox, ObjectLocationAnswer, ObjectLocateRequest
from app.object_vision import locate_object

JPEG = b"\xff\xd8\xff\xe0synthetic-test-frame\xff\xd9"
FRAME = base64.b64encode(JPEG).decode()
BODY = {"object_query": "my mug", "jpeg_base64": FRAME, "consent": True}
ANSWER = {"found": True, "label": "blue mug", "box": {"min_x": 0.2, "min_y": 0.3, "max_x": 0.5, "max_y": 0.7}, "confidence": 0.9, "reason": "Visible in the supplied frame"}

@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "objects.sqlite3"), bedrock_vision_model="test-vision"))) as client:
        client.post("/api/session"); client.headers["X-Faith-Client"] = "web"
        yield client

def test_snapshot_requires_session_and_browser_write_header(client):
    client.headers.pop("X-Faith-Client")
    assert client.post("/api/objects/locate", json=BODY).status_code == 403
    client.cookies.clear()
    assert client.post("/api/objects/locate", json=BODY).status_code == 401

@pytest.mark.parametrize("change", [{"consent": False}, {"jpeg_base64": "not-an-image-value"}, {"jpeg_base64": base64.b64encode(b"a" * 30).decode()}, {"jpeg_base64": "a" * 1_400_001}, {"object_query": ""}, {"url": "https://unapproved.example"}])
def test_snapshot_is_bounded_and_validation_never_echoes_image(client, change):
    response = client.post("/api/objects/locate", json={**BODY, **change})
    assert response.status_code == 422
    assert FRAME not in response.text

def test_unconfigured_vision_has_manual_memory_fallback(tmp_path):
    with TestClient(create_app(Settings(database_path=str(tmp_path / "disabled.sqlite3"), bedrock_vision_model="", baseten_vision_model=""))) as client:
        client.post("/api/session"); client.headers["X-Faith-Client"] = "web"
        response = client.post("/api/objects/locate", json=BODY)
        assert response.status_code == 503
        assert "Manual surface marking" in response.text
        assert client.get("/api/capabilities").json()["object_vision_configured"] is False

def test_vision_does_not_create_ticket_and_calls_are_limited(client, monkeypatch):
    calls = []
    def fake(body, settings): calls.append(body.object_query); return ObjectLocationAnswer.model_validate(ANSWER)
    monkeypatch.setattr("app.main.locate_object", fake)
    for _ in range(4):
        response = client.post("/api/objects/locate", json=BODY)
        assert response.status_code == 200
        assert response.json()["box"] == ANSWER["box"]
        assert response.headers["cache-control"] == "no-store"
    assert client.post("/api/objects/locate", json=BODY).status_code == 429
    assert len(calls) == 4
    assert client.get("/api/bookings").json()["bookings"] == []

def test_vision_failure_does_not_expose_image_or_provider_body(client, monkeypatch):
    def fail(*args): raise RuntimeError("private image " + FRAME)
    monkeypatch.setattr("app.main.locate_object", fail)
    response = client.post("/api/objects/locate", json=BODY)
    assert response.status_code == 502
    assert FRAME not in response.text
    assert "No location was inferred" in response.text

@pytest.mark.parametrize("confidence,found", [(0.9, True), (0.2, False)])
def test_bedrock_snapshot_contract_and_uncertainty(monkeypatch, confidence, found):
    runtime = MagicMock()
    runtime.converse.return_value = {"output": {"message": {"content": [{"text": json.dumps({**ANSWER, "confidence": confidence})}]}}}
    make_client = MagicMock(return_value=runtime)
    monkeypatch.setattr("boto3.client", make_client)
    monkeypatch.delenv("BASETEN_API_KEY", raising=False)
    result = locate_object(ObjectLocateRequest.model_validate(BODY), Settings(bedrock_vision_model="test-vision"))
    assert result.found is found
    request = runtime.converse.call_args.kwargs
    assert request["modelId"] == "test-vision"
    assert request["messages"][0]["content"][0]["image"]["source"]["bytes"] == JPEG
    assert "tools" not in request
    assert make_client.call_args.kwargs["config"].retries["max_attempts"] == 0
    if not found: assert result.box is None

@pytest.mark.parametrize("box", [{"min_x": 1.1, "min_y": 0, "max_x": 1, "max_y": 1}, {"min_x": 0.8, "min_y": 0, "max_x": 0.2, "max_y": 1}, {"min_x": float("nan"), "min_y": 0, "max_x": 1, "max_y": 1}])
def test_unusable_boxes_are_rejected(box):
    with pytest.raises(ValueError): ObjectBox.model_validate(box)

def test_not_found_cannot_contain_invented_box():
    with pytest.raises(ValueError): ObjectLocationAnswer.model_validate({**ANSWER, "found": False})


@pytest.mark.parametrize("confidence,found", [(0.9, True), (0.2, False)])
def test_baseten_snapshot_contract_and_uncertainty(monkeypatch, confidence, found):
    monkeypatch.setenv("BASETEN_API_KEY", "test-key")
    reply = MagicMock()
    reply.json.return_value = {"choices": [{"message": {"content": "```json\n" + json.dumps({**ANSWER, "confidence": confidence}) + "\n```"}}]}
    post = MagicMock(return_value=reply)
    monkeypatch.setattr("httpx.post", post)
    result = locate_object(ObjectLocateRequest.model_validate(BODY), Settings(baseten_vision_model="vl-model", bedrock_vision_model="ignored"))
    assert result.found is found
    request = post.call_args.kwargs["json"]
    assert post.call_args.args[0] == "https://inference.baseten.co/v1/chat/completions"
    assert post.call_args.kwargs["headers"]["Authorization"] == "Bearer test-key"
    assert request["model"] == "vl-model"
    assert request["chat_template_kwargs"] == {"thinking": False}
    assert request["messages"][1]["content"][0]["image_url"]["url"] == "data:image/jpeg;base64," + FRAME
    assert "tools" not in request
    if not found: assert result.box is None

def test_baseten_needs_key_and_model(tmp_path, monkeypatch):
    monkeypatch.delenv("BASETEN_API_KEY", raising=False)
    settings = Settings(database_path=str(tmp_path / "b.sqlite3"), bedrock_vision_model="", baseten_vision_model="vl-model")
    with TestClient(create_app(settings)) as client:
        assert client.get("/api/capabilities").json()["object_vision_configured"] is False
        monkeypatch.setenv("BASETEN_API_KEY", "test-key")
        assert client.get("/api/capabilities").json()["object_vision_configured"] is True
