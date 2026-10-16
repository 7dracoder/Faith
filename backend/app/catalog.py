"""Fictional inventory. Prices and access details must never be presented as live."""
from uuid import uuid4

from app.models import Category, Offer, SearchRequest


ROWS = [
    ("train", "The scenic route", "Faith Rail · demo", "08:40", "12:20", "3h 40m", 4900, 250, ["step_free", "text_updates", "companion"], "Riverside views. A little more room to breathe.", "rail"),
    ("flight", "A change of scenery", "Faith Air · demo", "10:15", "11:35", "1h 20m", 12900, 1200, ["step_free", "text_updates", "companion"], "A morning departure, with time for everything after.", "flight"),
    ("event", "An evening in good company", "Faith Sessions · demo", "19:00", "21:00", "2h", 3500, 450, ["step_free", "captions", "text_updates", "companion"], "Live music and open-captioned introductions at The Glasshouse.", "concert"),
    ("cinema", "Somewhere, beyond", "Faith Cinema · demo", "18:30", "20:40", "2h 10m", 1800, 150, ["step_free", "captions", "audio_description", "text_updates", "companion"], "A fictional adventure on the big screen, with open captions.", "cinema"),
    ("bus", "A window to somewhere new", "Faith Coach · demo", "09:00", "13:30", "4h 30m", 2400, 200, ["step_free", "text_updates", "companion"], "A comfortable coach journey. One bag. Endless possibilities.", "bus"),
    ("event", "The city, after hours", "Faith Arts · demo", "20:00", "22:30", "2h 30m", 4200, 500, ["step_free", "audio_description", "text_updates"], "A described gallery walk through an imagined city collection.", "gallery"),
    ("train", "Leave the rush behind", "Faith Rail · demo", "13:10", "17:00", "3h 50m", 6200, 250, ["step_free", "text_updates", "companion"], "A quieter afternoon journey with a reserved demo seat.", "rail"),
    ("cinema", "A world of our own", "Faith Cinema · demo", "15:00", "16:45", "1h 45m", 1400, 150, ["step_free", "captions", "text_updates"], "A relaxed, fictional matinee with open captions.", "cinema"),
]


def search_catalog(request: SearchRequest) -> list[Offer]:
    results = []
    required = {key for key, value in request.preferences.model_dump().items() if value}
    for category, title, operator, departure, arrival, duration, price, fee, features, description, art in ROWS:
        if request.category != Category.all and request.category.value != category:
            continue
        if not required.issubset(features):
            continue
        if request.max_price is not None and (price + fee) * request.passengers > request.max_price:
            continue
        travel = category in {"flight", "train", "bus"}
        results.append(Offer(
            id=uuid4().hex, category=Category(category), title=title, operator=operator,
            origin=request.origin if travel else "New York",
            destination=(request.destination or "Boston") if travel else "New York",
            date=request.date, departure=departure, arrival=arrival, duration=duration,
            price_minor=price, fee_minor=fee, features=features,
            access_note="Illustrative access features only. No venue, carrier, seat, assistance, or companion fare has been verified or reserved.",
            description=description, illustration=art,
        ))
    return results
