from datetime import date
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Category(str, Enum):
    all = "all"
    flight = "flight"
    train = "train"
    bus = "bus"
    cinema = "cinema"
    event = "event"


class AccessPreferences(StrictModel):
    step_free: bool = False
    captions: bool = False
    audio_description: bool = False
    text_updates: bool = True
    companion: bool = False


class SearchRequest(StrictModel):
    category: Category = Category.all
    origin: str = Field(default="New York", max_length=80)
    destination: str = Field(default="", max_length=80)
    date: date
    passengers: int = Field(default=1, ge=1, le=6)
    max_price: int | None = Field(default=None, ge=0, le=1_000_000)
    preferences: AccessPreferences = Field(default_factory=AccessPreferences)

    @field_validator("date")
    @classmethod
    def future_date(cls, value):
        if value < date.today():
            raise ValueError("Choose today or a future date.")
        return value


class IntentRequest(StrictModel):
    message: str = Field(min_length=2, max_length=1000)
    current: SearchRequest


class Offer(StrictModel):
    id: str
    category: Category
    title: str
    operator: str
    origin: str
    destination: str
    date: date
    departure: str
    arrival: str
    duration: str
    price_minor: int
    fee_minor: int
    currency: Literal["USD"] = "USD"
    features: list[str]
    access_note: str
    description: str
    illustration: str
    demo: Literal[True] = True


class QuoteRequest(StrictModel):
    offer_id: str = Field(min_length=1, max_length=80)
    passengers: int = Field(ge=1, le=6)
    preferences: AccessPreferences


class ConfirmRequest(StrictModel):
    quote_id: str = Field(min_length=1, max_length=80)
    accepted_demo: Literal[True]
    idempotency_key: str = Field(min_length=16, max_length=80, pattern=r"^[a-zA-Z0-9_-]+$")


class ResearchRequest(StrictModel):
    question: str = Field(min_length=5, max_length=500)
