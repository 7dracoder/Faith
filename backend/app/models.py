import math
from datetime import date, datetime, timedelta, timezone
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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


class AccessInfoRequest(StrictModel):
    category: Literal["flight", "train", "bus", "cinema", "event"]
    preferences: AccessPreferences = Field(default_factory=AccessPreferences)


class SpeechRequest(StrictModel):
    text: str = Field(min_length=1, max_length=600)
    consent: Literal[True]


def bounded_jpeg(value):
    import base64
    try:
        image = base64.b64decode(value, validate=True)
    except ValueError:
        raise ValueError("Use a base64 JPEG camera frame.") from None
    if len(image) > 1_000_000 or not image.startswith(b"\xff\xd8\xff") or not image.endswith(b"\xff\xd9"):
        raise ValueError("Use a JPEG camera frame under 1 MB.")
    return value


class ObjectLocateRequest(StrictModel):
    object_query: str = Field(min_length=2, max_length=120)
    jpeg_base64: str = Field(min_length=16, max_length=1_400_000, repr=False)
    consent: Literal[True]

    @field_validator("jpeg_base64")
    @classmethod
    def jpeg(cls, value):
        return bounded_jpeg(value)


class ObjectScanRequest(StrictModel):
    """One memory snapshot. The image is only forwarded to the vision model, never stored."""
    jpeg_base64: str = Field(min_length=16, max_length=1_400_000, repr=False)

    @field_validator("jpeg_base64")
    @classmethod
    def jpeg(cls, value):
        return bounded_jpeg(value)


class ObjectBox(StrictModel):
    min_x: float = Field(ge=0, le=1, allow_inf_nan=False)
    min_y: float = Field(ge=0, le=1, allow_inf_nan=False)
    max_x: float = Field(ge=0, le=1, allow_inf_nan=False)
    max_y: float = Field(ge=0, le=1, allow_inf_nan=False)

    @model_validator(mode="after")
    def ordered(self):
        if self.min_x >= self.max_x or self.min_y >= self.max_y:
            raise ValueError("Object box must have positive area.")
        return self


class ObjectLocationAnswer(StrictModel):
    found: bool
    label: str = Field(max_length=120)
    box: ObjectBox | None
    confidence: float = Field(ge=0, le=1, allow_inf_nan=False)
    reason: str = Field(max_length=240)

    @model_validator(mode="after")
    def consistent(self):
        if self.found != (self.box is not None):
            raise ValueError("Only a found object may have a box.")
        if self.found and not self.label:
            raise ValueError("A found object needs a label.")
        return self


OBJECT_LABEL = r"^[A-Za-z][A-Za-z0-9 '-]*$"
OBJECT_PLACE = r"^[A-Za-z0-9][A-Za-z0-9 .,'&-]*$"


class SeenObject(StrictModel):
    label: str = Field(max_length=200)
    box: ObjectBox
    confidence: float = Field(ge=0, le=1, allow_inf_nan=False)
    place: str | None = Field(default="", max_length=400)


class ObjectScanAnswer(StrictModel):
    objects: list[SeenObject] = Field(default_factory=list, max_length=40)


class MemoryEntry(StrictModel):
    """What memory keeps about one object: never the picture, the session, or the user's words."""
    label: str = Field(min_length=2, max_length=60, pattern=OBJECT_LABEL)
    place: str = Field(default="", max_length=120, pattern=r"^$|" + OBJECT_PLACE)
    seen_at: datetime
    position: list[float] | None = Field(default=None, min_length=3, max_length=3)
    ar_session: str | None = Field(default=None, pattern=r"^[0-9A-Fa-f-]{36}$")

    @field_validator("position")
    @classmethod
    def bounded_position(cls, value):
        if value is not None and not all(math.isfinite(v) and abs(v) <= 1000 for v in value):
            raise ValueError("Positions are meters in AR world space.")
        return value

    @field_validator("seen_at")
    @classmethod
    def recent(cls, value):
        now = datetime.now(timezone.utc)
        value = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        if not now - timedelta(days=7) <= value <= now + timedelta(minutes=5):
            raise ValueError("Sightings must be from the last week.")
        return value


class MemoryUpdate(StrictModel):
    entries: list[MemoryEntry] = Field(min_length=1, max_length=20)


PLACE = r"^[A-Za-z][A-Za-z .,'&:-]*$"


class SavedPreferences(StrictModel):
    """What the user asked Faith to remember. Never objects, camera frames, or location."""
    home_city: str | None = Field(default=None, min_length=2, max_length=60, pattern=PLACE)
    step_free: bool = False
    audio_description: bool = False
    companion: bool = False
    passengers: int | None = Field(default=None, ge=1, le=6)


class RealSearchRequest(StrictModel):
    category: Literal["flight", "train", "bus", "cinema", "event"]
    origin: str = Field(min_length=2, max_length=60, pattern=PLACE)
    destination: str = Field(default="", max_length=80, pattern=r"^$|" + PLACE)
    date: date

    @field_validator("date")
    @classmethod
    def soon(cls, value):
        if not date.today() <= value <= date.today() + timedelta(days=366):
            raise ValueError("Choose a date between today and one year from now.")
        return value


class TripRequest(StrictModel):
    option_id: str = Field(pattern=r"^live-[0-9a-f]{8}$")
