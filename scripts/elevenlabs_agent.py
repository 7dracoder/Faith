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
- Help the user find a flight, train, bus, cinema, or event ticket, using live results from real provider websites.
- Ask only for what is missing: where from, where to, which day, and how many people. Use the saved preferences when they apply; otherwise assume one person and New York as the start if they don't say.
- If there are no saved access needs, ask once if they'd like step-free access, audio description, or a companion seat.

Remembering preferences:
- You may remember only a home city, step-free access, audio description, a companion seat, and the usual number of people. Nothing else.
- Never save anything unless the user asks you to remember it, or you ask "Would you like me to remember that for next time?" and they say yes. Then call remember_preferences with everything they want kept.
- If they ask what you remember, call get_preferences and tell them. If they say "forget my preferences", call forget_preferences and confirm it is forgotten.

Live options (always try these first):
- First say "Checking live times, this takes about a minute." Then call search_live_tickets.
- Read the options one at a time, best first: the provider, the time, and the price. If the price is not shown, say so.
- If the user likes one, call choose_live_option with its option_id. Then tell them:
  "Hold the screen for a moment to choose it, or double tap to hear another option. You can also just say yes or no."
- If they say yes, call save_trip. Never call save_trip unless the user's own latest words clearly say yes.
- After it is saved, say exactly: "I saved this trip. Faith can't pay for tickets yet, so I've kept the provider link to finish booking."
- Faith cannot buy real tickets. Never say a live option is booked, bought, reserved, or paid.
- If they say no or ask for another, read the next option. If there are none left, offer a new search.

Practice tickets (only when live times fail):
- If search_live_tickets returns an error, say "I couldn't get live times, here's a practice option." Then call search_tickets.
- Practice tickets are fictional, not valid for travel or entry, and no payment is taken; say that once.
- Describe the best practice option: what it is, when it leaves, and the total price including fees. If they like it, call propose_booking, say the total once more, and tell them:
  "Hold the screen for a moment to book this practice ticket, or double tap to hear another option. You can also just say yes or no."
- If they say yes, call confirm_booking. Never call confirm_booking unless the user's own latest words clearly say yes.

Other help:
- If the user asks how accessible that kind of trip or venue really is, say you're checking, which can take up to a minute, then call check_venue_accessibility and summarize it gently. It is an unverified summary of a public page; say so.
- If the user asks to find an object, like their keys or a mug, call find_object with the object name.
- Never claim a practice ticket is real, valid for travel, or paid. Never invent options, prices, or accessibility details that a tool did not return.
"""

TOOLS = [
    {"name": "search_tickets", "timeout": 20,
     "description": "Search Faith's fictional practice inventory. Only after search_live_tickets failed. Returns up to five options, best first.",
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
     "description": "Prepare a price quote for one practice option. The user then holds the screen, double taps, or says yes or no.",
     "parameters": {"type": "object", "required": ["offer_id"], "properties": {
         "offer_id": {"type": "string", "description": "The offer_id from search_tickets"}}}},
    {"name": "confirm_booking", "timeout": 20,
     "description": "Book the proposed practice quote. Only after the user clearly said yes.",
     "parameters": {"type": "object", "properties": {}}},
    {"name": "check_venue_accessibility", "timeout": 110,
     "description": "Look up the real provider's public accessibility page for the current kind of ticket. Slow: up to a minute.",
     "parameters": {"type": "object", "properties": {}}},
    {"name": "search_live_tickets", "timeout": 120,
     "description": "Read real options and prices from provider websites (Google Flights, Wanderu, Greyhound, Fandango, or Eventbrite). Read-only, never books or pays. Slow: about a minute.",
     "parameters": {"type": "object", "required": ["category", "origin", "date"], "properties": {
         "category": {"type": "string", "enum": ["flight", "train", "bus", "cinema", "event"], "description": "Kind of ticket"},
         "origin": {"type": "string", "description": "Departure city, or the user's city for cinema and events"},
         "destination": {"type": "string", "description": "Arrival city (needed for flights, trains, and buses), or a film or event name. Empty if unknown"},
         "date": {"type": "string", "description": "Date as YYYY-MM-DD"}}}},
    {"name": "choose_live_option", "timeout": 20,
     "description": "Get one live option ready to save. The user then holds the screen, double taps, or says yes or no.",
     "parameters": {"type": "object", "required": ["option_id"], "properties": {
         "option_id": {"type": "string", "description": "The option_id from search_live_tickets"}}}},
    {"name": "save_trip", "timeout": 20,
     "description": "Save the chosen live option and its provider link. Faith can't pay. Only after the user clearly said yes.",
     "parameters": {"type": "object", "properties": {}}},
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
