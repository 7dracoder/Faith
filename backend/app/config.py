import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")


@dataclass(frozen=True)
class Settings:
    database_path: str = os.getenv("FAITH_DATABASE_PATH", "faith.sqlite3")
    secure_cookies: bool = os.getenv("FAITH_SECURE_COOKIES", "false").lower() == "true"
    ai_provider: str = os.getenv("FAITH_AI_PROVIDER", "local")
    aws_region: str = os.getenv("AWS_DEFAULT_REGION", "us-west-2")
    bedrock_model: str = os.getenv("BEDROCK_MODEL_ID", "")
    bedrock_vision_model: str = os.getenv("BEDROCK_VISION_MODEL_ID", "")
    baseten_vision_model: str = os.getenv("BASETEN_VISION_MODEL", "")
    provider_url: str = os.getenv("FAITH_PROVIDER_URL", "")
    integration_token: str = os.getenv("FAITH_INTEGRATION_TOKEN", "")
