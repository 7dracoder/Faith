"""Transactional demo orders, owned by an opaque session. No payment data."""
import json
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from uuid import uuid4


class BookingError(Exception):
    def __init__(self, status: int, message: str):
        self.status = status
        self.message = message


class BookingStore:
    def __init__(self, path: str):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS offers (
                id TEXT PRIMARY KEY, session TEXT NOT NULL, payload TEXT NOT NULL, expires TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS quotes (
                id TEXT PRIMARY KEY, session TEXT NOT NULL, payload TEXT NOT NULL, expires TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS bookings (
                id TEXT PRIMARY KEY, session TEXT NOT NULL, quote_id TEXT NOT NULL UNIQUE,
                idem TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(session, idem)
            );
        """)

    def close(self):
        self.db.close()

    def save_offers(self, session, offers):
        expires = (datetime.now(timezone.utc) + timedelta(minutes=30)).isoformat()
        with self.lock, self.db:
            self.db.executemany("INSERT INTO offers VALUES (?, ?, ?, ?)", [
                (o.id, session, o.model_dump_json(), expires) for o in offers
            ])
            self.db.execute("DELETE FROM offers WHERE expires < ?", (datetime.now(timezone.utc).isoformat(),))

    def quote(self, session, request):
        with self.lock, self.db:
            row = self.db.execute("SELECT * FROM offers WHERE id=? AND session=?", (request.offer_id, session)).fetchone()
            if not row:
                raise BookingError(404, "This option is no longer available. Search again.")
            now = datetime.now(timezone.utc)
            if datetime.fromisoformat(row["expires"]) <= now:
                raise BookingError(410, "This option has expired. Search again for current demo prices.")
            offer = json.loads(row["payload"])
            if any(enabled and key not in offer["features"] for key, enabled in request.preferences.model_dump().items()):
                raise BookingError(409, "This option does not list every requested access feature. Adjust your search.")
            quote = {
                "id": uuid4().hex, "offer": offer, "passengers": request.passengers,
                "preferences": request.preferences.model_dump(), "currency": "USD",
                "subtotal_minor": offer["price_minor"] * request.passengers,
                "fees_minor": offer["fee_minor"] * request.passengers,
                "total_minor": (offer["price_minor"] + offer["fee_minor"]) * request.passengers,
                "expires_at": (now + timedelta(minutes=10)).isoformat(), "demo": True,
                "notice": "This creates a demo ticket only. No payment, seat reservation, or admission is included.",
            }
            self.db.execute("INSERT INTO quotes VALUES (?, ?, ?, ?)",
                            (quote["id"], session, json.dumps(quote), quote["expires_at"]))
            return quote

    def confirm(self, session, request):
        with self.lock, self.db:
            previous = self.db.execute("SELECT * FROM bookings WHERE session=? AND idem=?", (session, request.idempotency_key)).fetchone()
            if previous:
                if previous["quote_id"] != request.quote_id:
                    raise BookingError(409, "This confirmation key was already used for another review.")
                return json.loads(previous["payload"])
            previous = self.db.execute("SELECT payload FROM bookings WHERE session=? AND quote_id=?", (session, request.quote_id)).fetchone()
            if previous:
                return json.loads(previous["payload"])
            row = self.db.execute("SELECT * FROM quotes WHERE id=? AND session=?", (request.quote_id, session)).fetchone()
            if not row:
                raise BookingError(404, "Review a ticket before confirming.")
            if datetime.fromisoformat(row["expires"]) <= datetime.now(timezone.utc):
                raise BookingError(410, "Your price review has expired. Choose the option again.")
            booking = {
                "id": "FTH-" + uuid4().hex[:10].upper(), "quote": json.loads(row["payload"]),
                "created_at": datetime.now(timezone.utc).isoformat(), "status": "demo_confirmed",
                "demo": True, "admission_valid": False,
            }
            self.db.execute("INSERT INTO bookings VALUES (?, ?, ?, ?, ?)",
                            (booking["id"], session, request.quote_id, request.idempotency_key, json.dumps(booking)))
            return booking

    def bookings(self, session):
        with self.lock:
            rows = self.db.execute("SELECT payload FROM bookings WHERE session=? ORDER BY rowid DESC", (session,)).fetchall()
            return [json.loads(row["payload"]) for row in rows]

    def cancel(self, session, booking_id):
        with self.lock, self.db:
            row = self.db.execute("SELECT payload FROM bookings WHERE id=? AND session=?", (booking_id, session)).fetchone()
            if not row:
                raise BookingError(404, "Ticket not found.")
            booking = json.loads(row["payload"])
            booking["status"] = "demo_cancelled"
            self.db.execute("UPDATE bookings SET payload=? WHERE id=? AND session=?", (json.dumps(booking), booking_id, session))
            return booking
