import asyncio
import logging
import os
import secrets
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from datetime import date, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from app.assistant import bedrock_intent, local_intent
from app.catalog import search_catalog
from app.config import Settings
from app.integrations import (ACCESS_SOURCES, REAL_SOURCES, access_question, configure_tracing, conversation_token, create_speech,
                              describe_preferences, forget_object_memory, forget_preferences, load_object_memory, load_preferences,
                              matching_objects, mirror_booking, operation, real_times, remember_objects, research_access,
                              save_preferences)
from app.models import (AccessInfoRequest, ConfirmRequest, IntentRequest, MemoryUpdate, ObjectLocateRequest, ObjectScanRequest,
                        QuoteRequest, RealSearchRequest, ResearchRequest, SavedPreferences, SearchRequest, SpeechRequest)
from app.object_vision import baseten_ready, locate_object, scan_objects, vision_configured
from app.store import BookingError, BookingStore

logger = logging.getLogger("faith")


def create_app(settings: Settings | None = None):
    settings = settings or Settings()
    store = BookingStore(settings.database_path)
    limits = defaultdict(deque)
    speech_budget = deque()
    speech_slots = asyncio.Semaphore(2)
    vision_budget = deque()
    vision_slots = asyncio.Semaphore(2)
    scan_budget = deque()
    scan_slots = asyncio.Semaphore(2)
    access_cache = {}
    access_budget = deque()
    access_slots = asyncio.Semaphore(2)
    agent_budget = deque()
    real_cache = {}
    real_budget = deque()

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

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        # Never echo a rejected camera frame back in validation diagnostics.
        return JSONResponse({"detail": [{"loc": item["loc"], "msg": item["msg"], "type": item["type"]}
                                        for item in error.errors()]}, status_code=422)

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
                "object_vision_configured": vision_configured(settings),
                "elevenlabs_configured": bool(os.getenv("ELEVENLABS_API_KEY")),
                "surreal_configured": bool(os.getenv("SURREAL_URL")),
                "phoenix_configured": bool(os.getenv("PHOENIX_COLLECTOR_ENDPOINT")),
                "arize_configured": bool(os.getenv("ARIZE_API_KEY") and os.getenv("ARIZE_SPACE_ID")),
                "anchor_configured": bool(os.getenv("ANCHOR_API_KEY") and settings.provider_url),
                "access_info_configured": bool(os.getenv("ANCHOR_API_KEY")),
                "agent_configured": bool(os.getenv("ELEVENLABS_API_KEY") and os.getenv("ELEVENLABS_AGENT_ID")),
                "preferences_configured": bool(os.getenv("SURREAL_URL")),
                "real_times_configured": bool(os.getenv("ANCHOR_API_KEY")),
                "object_memory_configured": baseten_ready(settings) and bool(os.getenv("SURREAL_URL"))}

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

    @app.post("/api/access-info")
    async def access_info(body: AccessInfoRequest, owner: str = Depends(session)):
        if not os.getenv("ANCHOR_API_KEY"):
            raise HTTPException(503, "Accessibility lookup is not configured. Contact the provider directly.")
        provider, url = ACCESS_SOURCES[body.category]
        key = (body.category, tuple(sorted(k for k, v in body.preferences.model_dump().items() if v)))
        now = time.monotonic()
        cached = access_cache.get(key)
        if not cached or cached[0] < now - 6 * 3600:
            while access_budget and access_budget[0][0] < now - 3600:
                access_budget.popleft()
            # Each lookup runs a cloud browser agent; bound cost per session and overall.
            if len(access_budget) >= 12 or sum(1 for stamp, token in access_budget if token == owner and stamp > now - 600) >= 3:
                raise HTTPException(429, "Accessibility lookup limit reached. Try again later or contact the provider directly.")
            access_budget.append((now, owner))
            try:
                with operation("faith.access_info", provider="anchor", category=body.category):
                    async with access_slots:
                        found = await research_access(access_question(body.preferences.model_dump()), url)
                summary = str(found["result"].get("result") or "").replace("**", "").strip()
                if found["result"].get("status") != "success" or not summary:
                    raise ValueError("Empty research result")
            except Exception:
                raise HTTPException(502, "Accessibility lookup is unavailable. Nothing was booked. Contact the provider directly.") from None
            cached = (now, summary[:4000])
            access_cache[key] = cached
        return {"provider": provider, "source": url, "summary": cached[1], "verified": False, "cached": cached[0] != now,
                "notice": f"AI summary of the public accessibility page from {provider}. Unverified and not specific to this demo ticket. Confirm with {provider} before you go."}

    @app.post("/api/real-search")
    async def real_search(body: RealSearchRequest, owner: str = Depends(session)):
        if body.category not in REAL_SOURCES:
            raise HTTPException(422, "Real times are only available for trains, buses, and cinemas. Check the airline or venue directly.")
        if not os.getenv("ANCHOR_API_KEY"):
            raise HTTPException(503, "Real times are not configured. Check the provider's website directly.")
        provider, url = REAL_SOURCES[body.category]
        key = (body.category, body.origin.lower(), body.destination.lower(), body.date)
        now = time.monotonic()
        cached = real_cache.get(key)
        if not cached or cached[0] < now - 1800:
            while real_budget and real_budget[0][0] < now - 3600:
                real_budget.popleft()
            # Each lookup runs a cloud browser agent; bound cost per session and overall.
            if len(real_budget) >= 12 or sum(1 for stamp, token in real_budget if token == owner and stamp > now - 600) >= 3:
                raise HTTPException(429, "Real-time lookup limit reached. Try again later or check the provider directly.")
            real_budget.append((now, owner))
            try:
                with operation("faith.real_search", provider="anchor", category=body.category):
                    async with access_slots:
                        found = await real_times(body.category, body.origin, body.destination, body.date.isoformat())
                summary = str(found.get("result") or "").replace("**", "").strip()
                if found.get("status") != "success" or not summary:
                    raise ValueError("Empty result")
            except Exception:
                raise HTTPException(502, f"Couldn't read real times from {provider} right now. Nothing was booked.") from None
            if len(real_cache) > 200:
                real_cache.clear()
            cached = (now, summary[:3000])
            real_cache[key] = cached
        return {"provider": provider, "source": url, "summary": cached[1], "verified": False, "cached": cached[0] != now,
                "notice": f"AI reading of {provider}'s public website. Unverified and may be out of date. "
                          f"Faith only books demo tickets; buy real tickets from {provider} directly."}

    def surreal_ready():
        if not os.getenv("SURREAL_URL"):
            raise HTTPException(503, "Preference memory is not configured, so nothing is saved.")

    @app.get("/api/preferences")
    async def get_preferences(owner: str = Depends(session)):
        surreal_ready()
        try:
            with operation("faith.preferences", action="read"):
                saved = await asyncio.wait_for(load_preferences(owner), timeout=5)
        except Exception:
            raise HTTPException(502, "Saved preferences are unavailable right now.") from None
        return {"preferences": saved, "summary": describe_preferences(saved)}

    @app.put("/api/preferences")
    async def put_preferences(body: SavedPreferences, owner: str = Depends(session)):
        surreal_ready()
        try:
            with operation("faith.preferences", action="save"):
                await asyncio.wait_for(save_preferences(owner, body.model_dump()), timeout=5)
        except Exception:
            raise HTTPException(502, "Couldn't save preferences right now. Nothing was saved.") from None
        return {"saved": True, "summary": describe_preferences(body.model_dump())}

    @app.delete("/api/preferences")
    async def delete_preferences(owner: str = Depends(session)):
        surreal_ready()
        try:
            with operation("faith.preferences", action="forget"):
                await asyncio.wait_for(forget_preferences(owner), timeout=5)
        except Exception:
            raise HTTPException(502, "Couldn't forget preferences right now. Please try again.") from None
        return {"forgotten": True}

    @app.post("/api/objects/locate")
    async def object_location(body: ObjectLocateRequest, owner: str = Depends(session)):
        if not vision_configured(settings):
            raise HTTPException(503, "Camera recognition needs a configured Baseten or Bedrock vision model. Manual surface marking and session memory still work on a supported iPhone.")
        now = time.monotonic()
        while vision_budget and vision_budget[0][0] < now - 3600:
            vision_budget.popleft()
        if len(vision_budget) >= 20 or sum(1 for stamp, token in vision_budget if token == owner and stamp > now - 60) >= 4:
            raise HTTPException(429, "Snapshot recognition limit reached. Try later or use session memory.")
        vision_budget.append((now, owner))
        try:
            async with vision_slots:
                result = await run_in_threadpool(locate_object, body, settings)
            return result.model_dump(mode="json")
        except Exception:
            # Do not log requests, image bytes, provider responses, or exception text.
            raise HTTPException(502, "Object recognition is unavailable. No location was inferred. Try session memory or manual surface marking.") from None

    @app.post("/api/objects/scan")
    async def object_scan(body: ObjectScanRequest, owner: str = Depends(session)):
        if not baseten_ready(settings):
            raise HTTPException(503, "Object memory needs a configured Baseten vision model. Live finding still works when configured.")
        now = time.monotonic()
        while scan_budget and scan_budget[0][0] < now - 3600:
            scan_budget.popleft()
        # Automatic scans: bound cost per session and overall, separate from spoken requests.
        if len(scan_budget) >= 600 or sum(1 for stamp, token in scan_budget if token == owner and stamp > now - 60) >= 20:
            raise HTTPException(429, "Object memory is pausing for a moment to limit cost.")
        scan_budget.append((now, owner))
        try:
            with operation("faith.object_scan", provider="baseten") as span:
                async with scan_slots:
                    result = await run_in_threadpool(scan_objects, body, settings)
                span.set_attribute("objects.count", len(result.objects))
            return result.model_dump(mode="json")
        except Exception:
            # The image is never stored, logged, or echoed.
            raise HTTPException(502, "Object memory scan is unavailable. Nothing was stored.") from None

    def memory_ready():
        if not os.getenv("SURREAL_URL"):
            raise HTTPException(503, "Object memory storage is not configured; the phone keeps its own copy.")

    @app.post("/api/objects/memory")
    async def remember_seen(body: MemoryUpdate, owner: str = Depends(session)):
        memory_ready()
        entries = [{**entry.model_dump(mode="json"), "seen_at": entry.seen_at.astimezone(timezone.utc).isoformat()}
                   for entry in body.entries]
        try:
            with operation("faith.object_memory", action="save") as span:
                count = await asyncio.wait_for(remember_objects(owner, entries), timeout=5)
                span.set_attribute("entries.count", len(entries))
        except Exception:
            raise HTTPException(502, "Couldn't store object memory right now. The phone keeps its own copy.") from None
        return {"stored": len(entries), "remembered": count}

    @app.get("/api/objects/memory")
    async def recall_seen(name: str = Query(default="", max_length=120), owner: str = Depends(session)):
        memory_ready()
        try:
            with operation("faith.object_memory", action="read"):
                items = await asyncio.wait_for(load_object_memory(owner), timeout=5)
        except Exception:
            raise HTTPException(502, "Object memory is unavailable right now.") from None
        return {"objects": matching_objects(items, name) if name else items}

    @app.delete("/api/objects/memory")
    async def forget_seen(owner: str = Depends(session)):
        memory_ready()
        try:
            with operation("faith.object_memory", action="forget"):
                await asyncio.wait_for(forget_object_memory(owner), timeout=5)
        except Exception:
            raise HTTPException(502, "Couldn't forget object memory right now. Please try again.") from None
        return {"forgotten": True}

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

    @app.post("/api/agent/session")
    async def agent_session(owner: str = Depends(session)):
        if not (os.getenv("ELEVENLABS_API_KEY") and os.getenv("ELEVENLABS_AGENT_ID")):
            raise HTTPException(503, "The voice booking assistant is not configured.")
        now = time.monotonic()
        while agent_budget and agent_budget[0][0] < now - 3600:
            agent_budget.popleft()
        if len(agent_budget) >= 30 or sum(1 for _, token in agent_budget if token == owner) >= 10:
            raise HTTPException(429, "Voice assistant limit reached. Try again later.")
        agent_budget.append((now, owner))
        try:
            with operation("faith.agent_session", provider="elevenlabs"):
                token = await conversation_token()
        except Exception:
            raise HTTPException(502, "The voice booking assistant is unavailable right now.") from None
        saved = "none"
        if os.getenv("SURREAL_URL"):
            try:
                saved = describe_preferences(await asyncio.wait_for(load_preferences(owner), timeout=3))
            except Exception:
                logger.warning("Saved preferences unavailable")
        return JSONResponse({"conversation_token": token, "today": date.today().isoformat(), "saved_preferences": saved},
                            headers={"Cache-Control": "no-store"})

    return app


app = create_app()
