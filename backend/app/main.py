import asyncio
import logging
import os
import secrets
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from app.assistant import bedrock_intent, local_intent
from app.catalog import search_catalog
from app.config import Settings
from app.integrations import configure_tracing, create_speech, mirror_booking, operation, research_access
from app.models import ConfirmRequest, IntentRequest, QuoteRequest, ResearchRequest, SearchRequest, SpeechRequest
from app.store import BookingError, BookingStore

logger = logging.getLogger("faith")


def create_app(settings: Settings | None = None):
    settings = settings or Settings()
    store = BookingStore(settings.database_path)
    limits = defaultdict(deque)
    speech_budget = deque()
    speech_slots = asyncio.Semaphore(2)

    @asynccontextmanager
    async def lifespan(app):
        provider = configure_tracing()
        yield
        store.close()
        if provider:
            provider.shutdown()

    app = FastAPI(title="Faith · accessible ticket booking", version="0.2.0", lifespan=lifespan)
    app.state.store = store

    @app.middleware("http")
    async def security_headers(request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Permissions-Policy"] = "camera=(), geolocation=(), microphone=(self), accelerometer=(self), gyroscope=(self)"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "connect-src 'self'; media-src 'self' blob:; font-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        )
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    def session(request: Request, response: Response, authorization: str | None = Header(default=None)):
        token = authorization.removeprefix("Bearer ") if authorization and authorization.startswith("Bearer ") else request.cookies.get("faith_session")
        if not token or not 32 <= len(token) <= 128 or not all(c.isalnum() or c in "-_" for c in token):
            raise HTTPException(401, "Start a Faith session first.")
        # Cookie-based writes also require a custom header to prevent cross-site form requests.
        if request.method != "GET" and not authorization and request.headers.get("X-Faith-Client") != "web":
            raise HTTPException(403, "Use the Faith app to make this request.")
        now = time.monotonic()
        # Bound the local-demo rate limiter without keeping an unbounded session map.
        if len(limits) > 2000:
            for key in list(limits):
                if not limits[key] or limits[key][-1] < now - 60:
                    del limits[key]
        entries = limits[token]
        while entries and entries[0] < now - 60:
            entries.popleft()
        if len(entries) >= 90:
            raise HTTPException(429, "Please wait a moment before trying again.")
        entries.append(now)
        return token

    @app.exception_handler(BookingError)
    async def booking_error(request, error):
        return JSONResponse({"detail": error.message}, status_code=error.status)

    @app.get("/health")
    def health():
        return {"ok": True, "product": "Faith", "mode": "demo"}

    @app.post("/api/session")
    def begin(request: Request, response: Response):
        current = request.cookies.get("faith_session", "")
        token = current if 32 <= len(current) <= 128 and all(c.isalnum() or c in "-_" for c in current) else secrets.token_urlsafe(32)
        response.set_cookie("faith_session", token, httponly=True, secure=settings.secure_cookies, samesite="strict", max_age=86400 * 7)
        return {"session_token": token, "mode": "demo", "product": "Faith"}

    @app.get("/api/capabilities")
    def capabilities():
        return {"mode": "demo", "categories": ["flight", "train", "bus", "cinema", "event"],
                "assistant": settings.ai_provider, "payments": False, "real_tickets": False,
                "bedrock_configured": bool(settings.bedrock_model),
                "elevenlabs_configured": bool(os.getenv("ELEVENLABS_API_KEY")),
                "surreal_configured": bool(os.getenv("SURREAL_URL")),
                "phoenix_configured": bool(os.getenv("PHOENIX_COLLECTOR_ENDPOINT")),
                "arize_configured": bool(os.getenv("ARIZE_API_KEY") and os.getenv("ARIZE_SPACE_ID")),
                "anchor_configured": bool(os.getenv("ANCHOR_API_KEY") and settings.provider_url)}

    @app.post("/api/search")
    def search(body: SearchRequest, owner: str = Depends(session)):
        with operation("faith.search", category=body.category.value, demo=True) as span:
            offers = search_catalog(body)
            store.save_offers(owner, offers)
            span.set_attribute("results.count", len(offers))
            return {"offers": [o.model_dump(mode="json") for o in offers], "demo": True,
                    "notice": "Fictional inventory and illustrative access details. Not live availability."}

    @app.post("/api/assistant")
    async def assistant(body: IntentRequest, owner: str = Depends(session)):
        with operation("faith.intent", provider=settings.ai_provider) as span:
            provider = settings.ai_provider
            try:
                if provider == "bedrock":
                    parsed = await run_in_threadpool(bedrock_intent, body, settings)
                else:
                    parsed = local_intent(body)
                    provider = "local"
            except Exception:
                span.set_attribute("fallback", True)
                try:
                    parsed = local_intent(body)
                except ValidationError:
                    raise HTTPException(422, "Check the date and passenger count in your request.") from None
                provider = "local_fallback"
            return {"search": parsed.model_dump(mode="json"), "provider": provider,
                    "message": "I’ve prepared your search. Review the fields and choose Find tickets."}

    @app.post("/api/quotes", status_code=201)
    def quote(body: QuoteRequest, owner: str = Depends(session)):
        with operation("faith.review", demo=True):
            return store.quote(owner, body)

    async def mirror(booking):
        try:
            # Mirror is best-effort; never undo a committed order or create it again on failure.
            import asyncio
            return await asyncio.wait_for(mirror_booking(booking), timeout=3)
        except Exception:
            logger.warning("Optional ticket mirror unavailable")
            return "unavailable"

    @app.post("/api/bookings", status_code=201)
    async def confirm(body: ConfirmRequest, owner: str = Depends(session)):
        with operation("faith.confirm", demo=True):
            booking = await run_in_threadpool(store.confirm, owner, body)
            await mirror(booking)
            return booking

    @app.get("/api/bookings")
    def bookings(owner: str = Depends(session)):
        return {"bookings": store.bookings(owner)}

    @app.post("/api/bookings/{booking_id}/cancel")
    async def cancel(booking_id: str, owner: str = Depends(session)):
        booking = await run_in_threadpool(store.cancel, owner, booking_id)
        await mirror(booking)
        return booking

    @app.post("/api/research")
    async def research(body: ResearchRequest, x_faith_integration_token: str = Header(default=""), owner: str = Depends(session)):
        if not settings.integration_token or not secrets.compare_digest(x_faith_integration_token, settings.integration_token):
            raise HTTPException(403, "Provider research is an operator-only integration.")
        if not os.getenv("ANCHOR_API_KEY") or not settings.provider_url:
            raise HTTPException(503, "Provider research is not configured.")
        try:
            with operation("faith.provider_research", provider="anchor"):
                return await research_access(body.question, settings.provider_url)
        except Exception:
            raise HTTPException(502, "Provider research is unavailable. No booking was attempted.") from None

    @app.post("/api/speech")
    async def speech(body: SpeechRequest, owner: str = Depends(session)):
        if not os.getenv("ELEVENLABS_API_KEY"):
            raise HTTPException(503, "ElevenLabs speech is not configured. Use device read-aloud or the visible text.")
        now = time.monotonic()
        while speech_budget and speech_budget[0][0] < now - 3600:
            speech_budget.popleft()
        # A single-process demo guard, not production billing/authentication controls.
        recent = sum(1 for timestamp, token, _ in speech_budget if token == owner and timestamp > now - 60)
        if recent >= 4 or len(speech_budget) >= 30 or sum(item[2] for item in speech_budget) + len(body.text) > 10_000:
            raise HTTPException(429, "Speech generation limit reached. Use device read-aloud or the visible text.")
        speech_budget.append((now, owner, len(body.text)))
        try:
            async with speech_slots:
                audio = await create_speech(body.text)
            return Response(audio, media_type="audio/mpeg", headers={"Cache-Control": "no-store"})
        except Exception:
            raise HTTPException(502, "Cloud speech is unavailable. Your text is still available; try device read-aloud.") from None

    web = Path(__file__).resolve().parents[2] / "web"
    if web.exists():
        app.mount("/", StaticFiles(directory=web, html=True), name="faith")
    return app


app = create_app()
