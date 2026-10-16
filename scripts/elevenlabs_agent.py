#!/usr/bin/env python3
"""Create or update Faith's ElevenLabs booking agent and its client tools.

    .venv/bin/python scripts/elevenlabs_agent.py

Reads ELEVENLABS_API_KEY from backend/.env and writes ELEVENLABS_AGENT_ID back to it.
The tools run inside the iOS app; the agent never sees session tokens or payment data.
"""
import os
import re
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

ENV = Path(__file__).resolve().parents[1] / "backend" / ".env"
API = "https://api.elevenlabs.io/v1/convai"
VOICE_ID = "EXAVITQu4vr4xnSDxMaL"  # "Sarah": soft and reassuring, same voice as the finder's lines

PROMPT = """You are Faith, a calm, warm ticket assistant for blind and low-vision people. Today is {{today}}.
Saved preferences for this user: {{saved_preferences}}.

How you speak:
- Speak slowly and gently, in short sentences. One idea at a time. Never use lists, symbols, or IDs.
- Say times like "nine thirty in the morning" and prices like "forty two dollars".

What you do:
- Help the user book a flight, train, bus, cinema, or event ticket. All tickets are fictional demo tickets; say that once, early.
- Ask only for what is missing: where from, where to, which day, and how many people. Use the saved preferences when they apply; otherwise assume one person and New York as the start if they don't say.
- If there are no saved access needs, ask once if they'd like step-free access, audio description, or a companion seat.

Remembering preferences:
- You may remember only a home city, step-free access, audio description, a companion seat, and the usual number of people. Nothing else.
- Never save anything unless the user asks you to remember it, or you ask "Would you like me to remember that for next time?" and they say yes. Then call remember_preferences with everything they want kept.
- If they ask what you remember, call get_preferences and tell them. If they say "forget my preferences", call forget_preferences and confirm it is forgotten.
- Call search_tickets. Then describe only the best option first: what it is, when it leaves, and the total price including fees.
- If the user likes it, call propose_booking with its offer_id. Then say the total once more and tell them:
  "Hold the screen for a moment to book it, or double tap to hear another option. You can also just say yes or no."
- If they say yes, call confirm_booking. Never call confirm_booking unless the user's own latest words clearly say yes.
- If they say no or ask for another, describe the next option from the same search. If there are none left, offer a new search.
- If the user asks for real times or real prices for a train, bus, or cinema, first say "Let me check the real website, this takes about a minute." Then call check_real_times and read back at most three options. Say these are real times from the provider's website, unverified, and that Faith can only book demo tickets; to buy the real ticket they should use the provider directly. Flights and events have no real-time check; say so.
- If the user asks how accessible that kind of trip or venue really is, say you're checking, which can take up to a minute, then call check_venue_accessibility and summarize it gently. It is an unverified summary of a public page; say so.
- If the user asks to find an object, like their keys or a mug, call find_object with the object name.
- Never claim a ticket is real, valid for travel, or paid. Never invent options, prices, or accessibility details that a tool did not return.
"""

TOOLS = [
    {"name": "search_tickets", "timeout": 20,
     "description": "Search Faith's fictional demo inventory. Returns up to five options, best first.",
     "parameters": {"type": "object", "required": ["category", "date"], "properties": {
         "category": {"type": "string", "enum": ["all", "flight", "train", "bus", "cinema", "event"], "description": "Kind of ticket"},
         "origin": {"type": "string", "description": "Departure city, or the user's city for cinema and events"},
         "destination": {"type": "string", "description": "Arrival city, or a film or event name. Empty if unknown"},
         "date": {"type": "string", "description": "Travel or event date as YYYY-MM-DD"},
         "passengers": {"type": "integer", "description": "Number of people, 1 to 6"},
         "max_price_usd": {"type": "integer", "description": "Optional most the user wants to pay per person, in dollars"},
         "step_free": {"type": "boolean", "description": "Needs step-free access"},
         "audio_description": {"type": "boolean", "description": "Wants audio description"},
         "companion": {"type": "boolean", "description": "Needs a companion seat"}}}},
    {"name": "propose_booking", "timeout": 20,
     "description": "Prepare a price quote for one option. The user then holds the screen, double taps, or says yes or no.",
     "parameters": {"type": "object", "required": ["offer_id"], "properties": {
         "offer_id": {"type": "string", "description": "The offer_id from search_tickets"}}}},
    {"name": "confirm_booking", "timeout": 20,
     "description": "Book the proposed quote. Only after the user clearly said yes.",
     "parameters": {"type": "object", "properties": {}}},
    {"name": "check_venue_accessibility", "timeout": 110,
     "description": "Look up the real provider's public accessibility page for the current kind of ticket. Slow: up to a minute.",
     "parameters": {"type": "object", "properties": {}}},
    {"name": "check_real_times", "timeout": 120,
     "description": "Read real departures or showtimes and prices from the provider's public website (Amtrak, Greyhound, or AMC). Read-only, never books. Slow: about a minute.",
     "parameters": {"type": "object", "required": ["category", "origin", "date"], "properties": {
         "category": {"type": "string", "enum": ["train", "bus", "cinema"], "description": "Kind of ticket"},
         "origin": {"type": "string", "description": "Departure city, or the user's city for cinema"},
         "destination": {"type": "string", "description": "Arrival city, or a film name. Empty if unknown"},
         "date": {"type": "string", "description": "Date as YYYY-MM-DD"}}}},
    {"name": "remember_preferences", "timeout": 15,
     "description": "Save the user's preferences for next time. Only after the user asked or clearly agreed.",
     "parameters": {"type": "object", "properties": {
         "home_city": {"type": "string", "description": "The user's home city. Empty if not given"},
         "step_free": {"type": "boolean", "description": "Needs step-free access"},
         "audio_description": {"type": "boolean", "description": "Wants audio description"},
         "companion": {"type": "boolean", "description": "Needs a companion seat"},
         "passengers": {"type": "integer", "description": "Usual number of people, 1 to 6"}}}},
    {"name": "get_preferences", "timeout": 15,
     "description": "Read the preferences this user asked Faith to remember.",
     "parameters": {"type": "object", "properties": {}}},
    {"name": "forget_preferences", "timeout": 15,
     "description": "Delete everything Faith remembers about this user's preferences.",
     "parameters": {"type": "object", "properties": {}}},
    {"name": "find_object", "timeout": 10,
     "description": "Switch to the object finder to locate an everyday object with the camera and sound.",
     "parameters": {"type": "object", "required": ["object"], "properties": {
         "object": {"type": "string", "description": "The object to find, like keys or blue mug"}}}},
]


def main():
    load_dotenv(ENV)
    key = os.getenv("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY in backend/.env first.")
    client = httpx.Client(headers={"xi-api-key": key}, timeout=30)

    existing = {tool["tool_config"]["name"]: tool["id"] for tool in client.get(f"{API}/tools").raise_for_status().json().get("tools", [])}
    tool_ids = []
    for tool in TOOLS:
        config = {"tool_config": {"type": "client", "name": tool["name"], "description": tool["description"],
                                  "parameters": tool["parameters"], "expects_response": True,
                                  "response_timeout_secs": tool["timeout"]}}
        if tool["name"] in existing:
            client.patch(f"{API}/tools/{existing[tool['name']]}", json=config).raise_for_status()
            tool_ids.append(existing[tool["name"]])
        else:
            tool_ids.append(client.post(f"{API}/tools", json=config).raise_for_status().json()["id"])

    agent = {
        "name": "Faith booking assistant",
        "conversation_config": {
            "agent": {"first_message": "", "language": "en",
                      "dynamic_variables": {"dynamic_variable_placeholders": {"today": "2026-01-01", "saved_preferences": "none"}},
                      "prompt": {"prompt": PROMPT, "llm": "gemini-2.5-flash", "temperature": 0.3, "tool_ids": tool_ids}},
            "tts": {"voice_id": VOICE_ID, "model_id": "eleven_flash_v2", "stability": 0.75,
                    "similarity_boost": 0.7, "speed": 0.9},
        },
        "platform_settings": {"auth": {"enable_auth": True}},
    }
    agent_id = os.getenv("ELEVENLABS_AGENT_ID", "")
    if agent_id:
        client.patch(f"{API}/agents/{agent_id}", json=agent).raise_for_status()
    else:
        agent_id = client.post(f"{API}/agents/create", json=agent).raise_for_status().json()["agent_id"]
        text = ENV.read_text()
        line = f"ELEVENLABS_AGENT_ID={agent_id}"
        text = re.sub(r"^ELEVENLABS_AGENT_ID=.*$", line, text, flags=re.M) if "ELEVENLABS_AGENT_ID=" in text else text.rstrip("\n") + "\n" + line + "\n"
        ENV.write_text(text)
    print(f"Agent ready with {len(tool_ids)} tools. ELEVENLABS_AGENT_ID saved in backend/.env.")


if __name__ == "__main__":
    main()
