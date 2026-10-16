import pytest


@pytest.fixture(autouse=True)
def disable_external_services(monkeypatch):
    """Local credentials must never turn synthetic unit tests into cloud calls."""
    for key in ["ARIZE_SPACE_ID", "PHOENIX_COLLECTOR_ENDPOINT", "SURREAL_URL", "SURREAL_TOKEN", "ANCHOR_API_KEY", "ELEVENLABS_API_KEY", "ELEVENLABS_AGENT_ID", "BASETEN_API_KEY"]:
        monkeypatch.delenv(key, raising=False)
