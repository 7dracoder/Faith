"use strict";

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const labels = { all: "Everything", flight: "Flights", train: "Trains", bus: "Buses", cinema: "Cinema", event: "Events" };
const featureLabels = { step_free: "Step-free", captions: "Captions", audio_description: "Audio description", text_updates: "Text updates", companion: "Companion place" };
const symbols = { flight: "↗", train: "▤", bus: "▣", cinema: "▻", event: "♫" };
const state = { category: "all", offers: [], bookings: [], quote: null, bookingKey: null, pendingCancel: null, busy: false, page: "explore", motion: false, motionBaseline: null, motionReady: true, motionIndex: -1, lastMotion: 0, recognition: null, search: null };
let prefs = { contrast: false, large: false, reduced: false, haptics: false, speech: false };
try { prefs = { ...prefs, ...JSON.parse(localStorage.getItem("faith.preferences") || "{}") }; } catch { /* Private browsing may disable storage. */ }
const money = (minor) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: minor % 100 ? 2 : 0 }).format(minor / 100);
const escapeHTML = (value) => String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
const humanDate = (value) => new Date(`${value}T12:00:00`).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
const tomorrow = new Date(); tomorrow.setDate(tomorrow.getDate() + 1);
const dateInputValue = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
$("#date").value = dateInputValue(tomorrow);
$("#date").min = dateInputValue(new Date());

async function api(path, options = {}) {
  const response = await fetch(`/api/${path}`, {
    credentials: "same-origin", ...options,
    headers: { "Content-Type": "application/json", "X-Faith-Client": "web", ...options.headers },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    let message = "Faith couldn’t complete that step. Please try again.";
    if (typeof result.detail === "string") message = result.detail;
    if (Array.isArray(result.detail)) message = result.detail.map((item) => item.msg.replace("Value error, ", "")).join(" ");
    const error = new Error(message); error.status = response.status; throw error;
  }
  return result;
}

function speak(message) {
  if (!("speechSynthesis" in window)) return;
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(message);
  utterance.rate = 0.95;
  window.speechSynthesis.speak(utterance);
}

let speechURL, speechRequest;
function stopCloudSpeech(clear = false) {
  speechRequest?.abort(); speechRequest = null;
  $("#speech-audio").pause();
  if (clear) {
    $("#speech-audio").removeAttribute("src"); $("#speech-audio").load();
    if (speechURL) URL.revokeObjectURL(speechURL);
    speechURL = null; $("#speech-result").hidden = true; $("#speech-transcript").textContent = "";
  }
}
function updateSpeechButton() {
  $("#generate-speech").disabled = !$("#speech-consent").checked || !$("#speech-text").value.trim() || Boolean(speechRequest);
}
async function generateSpeech() {
  if (!$("#speech-consent").checked || speechRequest) return;
  const text = $("#speech-text").value.trim(); if (!text) return;
  stopCloudSpeech(true);
  const controller = new AbortController(); speechRequest = controller;
  updateSpeechButton(); $("#speech-status").textContent = "Generating audio. Your message remains available as text.";
  try {
    const response = await fetch("/api/speech", { method: "POST", credentials: "same-origin", signal: controller.signal,
      headers: { "Content-Type": "application/json", "X-Faith-Client": "web" }, body: JSON.stringify({ text, consent: true }) });
    if (!response.ok) { const result = await response.json(); throw new Error(typeof result.detail === "string" ? result.detail : "Check your message and try again."); }
    const blob = await response.blob();
    if (controller.signal.aborted) return;
    speechURL = URL.createObjectURL(blob); $("#speech-audio").src = speechURL;
    $("#speech-transcript").textContent = text; $("#speech-result").hidden = false;
    $("#speech-status").textContent = "Audio ready. Press Play when you want to hear it. Nothing was booked.";
  } catch (error) {
    if (error.name !== "AbortError") $("#speech-status").textContent = `${error.message} You can still show your message or use device read-aloud.`;
  } finally { if (speechRequest === controller) speechRequest = null; updateSpeechButton(); }
}
function pageSpeechSummary() {
  const items = state.page === "wallet" ? state.bookings.slice(0, 3).map((b) => `${b.quote.offer.title}, ${b.quote.offer.date}, ${money(b.quote.total_minor)} total, ${b.status.replaceAll("_", " ")}.`) : state.offers.slice(0, 3).map((o) => `${o.title}, ${o.date} at ${o.departure}, ${money((o.price_minor + o.fee_minor) * (state.search?.passengers || 1))} total including fees.`);
  return `Faith demo. No payment, real reservation, or admission. ${items.join(" ")}`.slice(0, 600);
}

function haptic(kind = "step") {
  if (prefs.haptics && "vibrate" in navigator) navigator.vibrate(kind === "success" ? [70, 60, 70] : 30);
}

let toastTimer;
function announce(message, success = false) {
  clearTimeout(toastTimer);
  $("#error").hidden = true;
  $("#status").textContent = message;
  if (prefs.speech) speak(message);
  haptic(success ? "success" : "step");
  toastTimer = setTimeout(() => { $("#status").textContent = ""; }, 9000);
}

function showError(error) {
  $("#error").textContent = error instanceof TypeError ? "The server is unavailable. Check your connection and try again." : error.message;
  $("#error").hidden = false;
  if (prefs.speech) speak($("#error").textContent);
}

function currentSearch() {
  const preferences = { text_updates: true };
  for (const key of ["step_free", "captions", "audio_description", "companion"]) preferences[key] = $(`input[name="${key}"]`).checked;
  const budget = $("#budget").value;
  return { category: state.category, origin: $("#origin").value.trim(), destination: $("#destination").value.trim(), date: $("#date").value, passengers: Number($("#passengers").value), max_price: budget === "" ? null : Math.round(Number(budget) * 100), preferences };
}

function setCategory(category) {
  state.category = category;
  $$(".category").forEach((button) => {
    const selected = button.dataset.category === category;
    button.classList.toggle("active", selected);
    button.setAttribute("aria-pressed", String(selected));
  });
  const local = category === "cinema" || category === "event";
  $("#destination").disabled = local;
  $("#destination").setAttribute("aria-label", local ? "Destination is New York for local demo experiences" : "Destination city");
}

function applySearch(search) {
  setCategory(search.category);
  for (const field of ["origin", "destination", "date", "passengers"]) $(`#${field}`).value = search[field];
  $("#budget").value = search.max_price === null ? "" : search.max_price / 100;
  for (const key of ["step_free", "captions", "audio_description", "companion"]) $(`input[name="${key}"]`).checked = Boolean(search.preferences[key]);
}

async function searchTickets(initial = false) {
  if (state.busy || !$("#search-form").reportValidity()) return;
  state.busy = true;
  $("#error").hidden = true;
  $(".search-submit").disabled = true;
  $("#results").setAttribute("aria-busy", "true");
  $("#results").innerHTML = '<div class="loading-state">Finding a little possibility…</div>';
  $("#empty-state").hidden = true;
  try {
    const search = currentSearch();
    const data = await api("search", { method: "POST", body: search });
    state.offers = data.offers;
    state.search = search;
    state.motionIndex = -1;
    $("#results-eyebrow").textContent = initial ? "A LITTLE INSPIRATION" : "YOUR NEXT CHAPTER STARTS HERE";
    $("#results-title").textContent = initial ? "Good things are out there." : `${search.category === "all" ? "Possibilities" : labels[search.category]} for your kind of day.`;
    const requested = Object.entries(search.preferences).filter(([key, enabled]) => enabled && key !== "text_updates").map(([key]) => featureLabels[key]);
    $("#search-summary").textContent = `${humanDate(search.date)} · ${search.passengers} ${search.passengers === 1 ? "person" : "people"}${requested.length ? " · " + requested.join(" · ") : ""}${search.max_price !== null ? " · up to " + money(search.max_price) + " total" : ""}. All options are fictional.`;
    $("#search-summary").hidden = initial;
    renderOffers();
    if (!initial) {
      $("#results-title").focus();
      announce(`${data.offers.length} demo options found. Prices include all people and fees.`);
    }
  } catch (error) {
    state.offers = [];
    $("#results").innerHTML = '<div class="loading-state">Your search couldn’t load. Use Find tickets to try again.</div>';
    $("#results-count").textContent = "Search unavailable";
    showError(error);
  } finally {
    state.busy = false;
    $(".search-submit").disabled = false;
    $("#results").setAttribute("aria-busy", "false");
  }
}

function renderOffers() {
  const offers = [...state.offers];
  if ($("#sort").value === "price") offers.sort((a, b) => a.price_minor + a.fee_minor - b.price_minor - b.fee_minor);
  $("#results-count").textContent = `${offers.length} demo ${offers.length === 1 ? "option" : "options"}`;
  $("#empty-state").hidden = offers.length > 0;
  $("#results").innerHTML = offers.map((offer) => {
    const travel = ["flight", "train", "bus"].includes(offer.category);
    const people = state.search.passengers;
    return `<article class="option-card">
      <div class="card-art art-${escapeHTML(offer.illustration)}" aria-hidden="true"><img src="/assets/journey.svg" alt=""><span class="card-abstract">${symbols[offer.category]}</span><span class="card-category">${labels[offer.category].toUpperCase()}</span><span class="card-demo">DEMO EXPERIENCE</span></div>
      <div class="card-content"><div class="card-meta"><span>${escapeHTML(humanDate(offer.date))}</span><span aria-hidden="true">·</span><span>${escapeHTML(offer.departure)}</span></div>
        <h3>${escapeHTML(offer.title)}</h3><p class="card-route">${escapeHTML(travel ? `${offer.origin} → ${offer.destination}` : offer.destination)} · ${escapeHTML(offer.duration)}</p>
        <p class="card-description">${escapeHTML(offer.description)}</p><div class="feature-tags" aria-label="Illustrative access features">${offer.features.filter((f) => f !== "text_updates").map((f) => `<span class="feature-tag">${escapeHTML(featureLabels[f] || f)}</span>`).join("")}</div>
        <div class="card-bottom"><span class="price">${money((offer.price_minor + offer.fee_minor) * people)}<small>${people > 1 ? `Total for ${people} people` : "Per person"} · incl. fees</small></span><button class="review-button" data-review="${escapeHTML(offer.id)}" aria-label="Review ${escapeHTML(offer.title)}, ${money((offer.price_minor + offer.fee_minor) * people)} total">Take a look <span aria-hidden="true">↗</span></button></div>
      </div></article>`;
  }).join("");
}

function openDialog(id) {
  const dialog = $(`#${id}`);
  if (!dialog.open) dialog.showModal();
}

async function reviewTicket(id, button) {
  if (state.busy || !state.search) return;
  state.busy = true; button.disabled = true;
  try {
    const quote = await api("quotes", { method: "POST", body: { offer_id: id, passengers: state.search.passengers, preferences: state.search.preferences } });
    state.quote = quote; state.bookingKey = crypto.randomUUID();
    const offer = quote.offer;
    const requested = Object.entries(quote.preferences).filter(([, enabled]) => enabled).map(([key]) => featureLabels[key]);
    $("#review-content").innerHTML = `<h3 class="review-heading">${escapeHTML(offer.title)}</h3><p class="review-meta">${escapeHTML(offer.operator)}<br>${escapeHTML(offer.origin)} → ${escapeHTML(offer.destination)}<br>${escapeHTML(humanDate(offer.date))} · ${escapeHTML(offer.departure)}–${escapeHTML(offer.arrival)} · ${quote.passengers} ${quote.passengers === 1 ? "person" : "people"}</p><div class="review-features"><strong>Your requested features</strong><p>${escapeHTML(requested.join(" · "))}</p><p>${escapeHTML(offer.access_note)}</p></div><div class="line-item"><span>Tickets × ${quote.passengers}</span><span>${money(quote.subtotal_minor)}</span></div><div class="line-item"><span>All demo booking fees</span><span>${money(quote.fees_minor)}</span></div><div class="line-item total"><span>Total · USD</span><span>${money(quote.total_minor)}</span></div><p class="demo-notice">${escapeHTML(quote.notice)}</p><p class="review-expiry">This price review expires at ${escapeHTML(new Date(quote.expires_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))}.</p><label class="acknowledge"><input id="accept-demo" type="checkbox"><span>I understand this is a demo ticket with no payment or real reservation.</span></label><button class="primary-button full-width" id="confirm-booking" disabled>Create demo ticket <span aria-hidden="true">↗</span></button><p id="review-error" role="alert" class="review-expiry"></p>`;
    openDialog("review-dialog");
    announce("Your price review is ready. Check the details before creating a demo ticket.");
  } catch (error) { showError(error); }
  finally { state.busy = false; button.disabled = false; }
}

async function confirmBooking(button) {
  if (state.busy || !state.quote || !$("#accept-demo").checked) return;
  state.busy = true; button.disabled = true; button.textContent = "Saving your demo ticket…";
  try {
    const booking = await api("bookings", { method: "POST", body: { quote_id: state.quote.id, accepted_demo: true, idempotency_key: state.bookingKey } });
    state.quote = null;
    $("#review-dialog").close();
    await showWallet();
    announce(`Demo ticket ${booking.id} saved. No payment or real reservation was made.`, true);
  } catch (error) {
    $("#review-error").textContent = error.message;
    if (error.status === 410) { button.textContent = "Review expired · search again"; state.quote = null; }
    else { button.disabled = false; button.textContent = "Try saving demo ticket again"; }
  } finally { state.busy = false; }
}

function setPage(page) {
  state.page = page;
  $("#explore-page").hidden = page !== "explore";
  $("#wallet-page").hidden = page !== "wallet";
  for (const [id, target] of [["nav-explore", "explore"], ["nav-tickets", "wallet"]]) {
    $(`#${id}`).classList.toggle("active", page === target);
    if (page === target) $(`#${id}`).setAttribute("aria-current", "page"); else $(`#${id}`).removeAttribute("aria-current");
  }
  if (page === "wallet") $("#wallet-title").focus();
  else $("#main").focus();
  window.scrollTo({ top: 0, behavior: "instant" });
}

async function loadWallet() {
  const response = await api("bookings");
  state.bookings = response.bookings;
  const count = state.bookings.filter((ticket) => ticket.status !== "demo_cancelled").length;
  $("#ticket-count").textContent = count;
  $("#ticket-count").hidden = count === 0;
}

async function showWallet() {
  setPage("wallet");
  $("#wallet-list").innerHTML = '<div class="loading-state">Opening your next chapters…</div>';
  try { await loadWallet(); renderWallet(); }
  catch (error) { $("#wallet-list").innerHTML = '<div class="empty-wallet"><h2>Your tickets couldn’t load.</h2><p>Select My tickets to try again.</p></div>'; showError(error); }
}

function renderWallet() {
  $("#wallet-list").innerHTML = state.bookings.length ? state.bookings.map((booking) => {
    const offer = booking.quote.offer;
    const cancelled = booking.status === "demo_cancelled";
    return `<article class="wallet-card"><span class="ticket-status${cancelled ? " cancelled" : ""}">${cancelled ? "DEMO CANCELLED" : "DEMO TICKET · NOT VALID FOR ENTRY"}</span><h2>${escapeHTML(offer.title)}</h2><p>${escapeHTML(offer.origin)} → ${escapeHTML(offer.destination)}</p><p>${escapeHTML(humanDate(offer.date))} · ${escapeHTML(offer.departure)} · ${booking.quote.passengers} ${booking.quote.passengers === 1 ? "person" : "people"}</p><p>${money(booking.quote.total_minor)} demo total · No payment made</p><p class="reference">${escapeHTML(booking.id)}</p><p>${escapeHTML(booking.quote.notice)}</p><div class="wallet-actions"><button class="secondary-button" data-download="${escapeHTML(booking.id)}" aria-label="Download demo ticket for ${escapeHTML(offer.title)}">Save text ticket ↓</button>${cancelled ? "" : `<button class="text-button" data-cancel="${escapeHTML(booking.id)}" aria-label="Cancel demo ticket for ${escapeHTML(offer.title)}">Cancel demo ticket</button>`}</div></article>`;
  }).join("") : '<div class="empty-wallet"><h2>Something to look forward to.</h2><p>Your demo tickets will appear here. Find an experience to start your next chapter.</p></div>';
}

function downloadTicket(id) {
  const booking = state.bookings.find((item) => item.id === id);
  if (!booking) return;
  const offer = booking.quote.offer;
  const text = ["FAITH — DEMO TICKET", "NOT VALID FOR TRAVEL, ENTRY, OR ADMISSION", "", offer.title, `${offer.origin} to ${offer.destination}`, `${offer.date} at ${offer.departure}`, `${booking.quote.passengers} people`, `Demo total: ${money(booking.quote.total_minor)}`, `Reference: ${booking.id}`, `Status: ${booking.status}`, "", booking.quote.notice, "Access features are illustrative and unverified."].join("\n");
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
  const anchor = document.createElement("a"); anchor.href = url; anchor.download = `Faith-${booking.id}.txt`; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  announce("Your accessible text ticket has been downloaded.");
}

async function interpretRequest(event) {
  event.preventDefault();
  if (state.busy) return;
  const message = $("#request").value.trim();
  if (message.length < 2) { announce("Describe what you’d like to do, or use the search fields above."); $("#request").focus(); return; }
  state.busy = true; $("#interpret").disabled = true;
  try {
    const result = await api("assistant", { method: "POST", body: { message, current: currentSearch() } });
    applySearch(result.search);
    announce(`${result.message} ${labels[result.search.category]}, ${result.search.passengers} people, ${humanDate(result.search.date)}${result.search.max_price !== null ? ", up to " + money(result.search.max_price) + " total" : ""}.`);
    $(".search-submit").focus();
  } catch (error) { showError(error); }
  finally { state.busy = false; $("#interpret").disabled = false; }
}

function applyPreferences() {
  for (const [key, className] of [["contrast", "high-contrast"], ["large", "large-text"], ["reduced", "reduced-motion"]]) document.body.classList.toggle(className, Boolean(prefs[key]));
  for (const key of Object.keys(prefs)) { const input = $(`#setting-${key}`); if (input) input.checked = Boolean(prefs[key]); }
  try { localStorage.setItem("faith.preferences", JSON.stringify(prefs)); } catch { /* Preferences still work for this visit. */ }
}

function disableMotion(message = "Motion controls are off. Text and touch are ready.") {
  window.removeEventListener("deviceorientation", onOrientation);
  state.motion = false; state.motionBaseline = null; state.motionReady = true;
  $$(".motion-focused").forEach((el) => el.classList.remove("motion-focused"));
  $("#toggle-motion").textContent = "Enable motion controls";
  $("#sensor-status").textContent = "Text & touch ready";
  $("#motion-note").textContent = message;
}

async function toggleMotion() {
  if (state.motion) { disableMotion(); announce("Motion controls disabled."); return; }
  if (!window.DeviceOrientationEvent) { $("#motion-note").textContent = "Motion isn’t available in this browser. Use text, touch, or a keyboard."; return; }
  try {
    if (typeof DeviceOrientationEvent.requestPermission === "function") {
      if (await DeviceOrientationEvent.requestPermission() !== "granted") { $("#motion-note").textContent = "Motion permission was not granted. All standard controls still work."; return; }
    }
    state.motion = true; state.motionBaseline = null; state.motionReady = true;
    window.addEventListener("deviceorientation", onOrientation);
    $("#toggle-motion").textContent = "Disable motion controls";
    $("#motion-note").textContent = "Hold comfortably for calibration, then close this panel. Tilt left/right and return to center between results.";
    $("#sensor-status").textContent = "Motion: calibrating…";
    setTimeout(() => { if (state.motion && state.motionBaseline === null) { disableMotion("No motion data received. This device may need HTTPS or may not have a sensor."); } }, 5000);
  } catch { $("#motion-note").textContent = "Motion couldn’t start. Try a supported device over HTTPS."; }
}

function onOrientation(event) {
  if (!state.motion || event.gamma === null) return;
  if (state.motionBaseline === null) { state.motionBaseline = event.gamma; $("#sensor-status").textContent = "Tilt controls ready"; return; }
  if ($$("dialog[open]").length || state.page !== "explore") return;
  const tilt = event.gamma - state.motionBaseline;
  if (Math.abs(tilt) < 6) state.motionReady = true;
  if (Math.abs(tilt) < 16 || !state.motionReady || Date.now() - state.lastMotion < 1100) return;
  const buttons = $$("[data-review]"); if (!buttons.length) return;
  state.motionReady = false; state.lastMotion = Date.now();
  state.motionIndex = Math.max(0, Math.min(buttons.length - 1, state.motionIndex + (tilt > 0 ? 1 : -1)));
  $$(".motion-focused").forEach((el) => el.classList.remove("motion-focused"));
  buttons[state.motionIndex].classList.add("motion-focused");
  buttons[state.motionIndex].focus();
  $("#sensor-status").textContent = `Option ${state.motionIndex + 1} of ${buttons.length}`;
  haptic();
}

function stopDictation() {
  if (state.recognition) state.recognition.stop();
  state.recognition = null;
  $("#dictate").setAttribute("aria-pressed", "false");
  $("#dictate").setAttribute("aria-label", "Dictate a search");
}

function dictate() {
  if (state.recognition) { stopDictation(); return; }
  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognition) { announce("Dictation isn’t supported in this browser. Type your request or use your device keyboard’s microphone."); $("#request").focus(); return; }
  const recognition = new SpeechRecognition();
  recognition.lang = "en-US"; recognition.interimResults = true; recognition.continuous = false;
  recognition.onresult = (event) => { $("#request").value = [...event.results].map((result) => result[0].transcript).join(" "); };
  recognition.onerror = (event) => { announce(event.error === "not-allowed" ? "Microphone permission wasn’t granted. You can type your request instead." : "Dictation stopped. Your text is still editable."); stopDictation(); };
  recognition.onend = () => { stopDictation(); $("#request").focus(); };
  try { recognition.start(); state.recognition = recognition; $("#dictate").setAttribute("aria-pressed", "true"); $("#dictate").setAttribute("aria-label", "Stop dictation"); announce("Listening. Your words appear in the request field. Press the microphone to stop."); }
  catch { announce("Dictation couldn’t start. Type your request instead."); }
}

$("#search-form").addEventListener("submit", (event) => { event.preventDefault(); searchTickets(); });
$("#assistant-form").addEventListener("submit", interpretRequest);
$("#sort").addEventListener("change", renderOffers);
$$(".category").forEach((button) => button.addEventListener("click", () => { setCategory(button.dataset.category); haptic(); }));
$("#results").addEventListener("click", (event) => { const button = event.target.closest("[data-review]"); if (button) reviewTicket(button.dataset.review, button); });
$("#review-content").addEventListener("change", (event) => { if (event.target.id === "accept-demo" && state.quote) $("#confirm-booking").disabled = !event.target.checked; });
$("#review-content").addEventListener("click", (event) => { const button = event.target.closest("#confirm-booking"); if (button) confirmBooking(button); });
$("#nav-explore").addEventListener("click", () => setPage("explore"));
$("#nav-tickets").addEventListener("click", showWallet);
$("#wallet-explore").addEventListener("click", () => setPage("explore"));
for (const id of ["nav-how", "footer-help"]) $(`#${id}`).addEventListener("click", () => openDialog("help-dialog"));
for (const id of ["open-access", "ways-access"]) $(`#${id}`).addEventListener("click", () => openDialog("access-dialog"));
$$("[data-close]").forEach((button) => button.addEventListener("click", () => $(`#${button.dataset.close}`).close()));
$$(".settings-list input").forEach((input) => input.addEventListener("change", () => { prefs[input.id.replace("setting-", "")] = input.checked; applyPreferences(); if (!prefs.speech && "speechSynthesis" in window) window.speechSynthesis.cancel(); haptic(); }));
$("#toggle-motion").addEventListener("click", toggleMotion);
$("#generate-speech").addEventListener("click", generateSpeech);
$("#speech-audio").addEventListener("play", () => { $("#speech-status").textContent = "Playing generated audio. The spoken text stays visible below."; });
$("#speech-audio").addEventListener("pause", () => { $("#speech-status").textContent = "Audio paused. Your text remains visible."; });
$("#speech-audio").addEventListener("ended", () => { $("#speech-status").textContent = "Audio finished. Replay or use the visible text."; });
$("#speech-consent").addEventListener("change", updateSpeechButton);
$("#speech-text").addEventListener("input", () => { stopCloudSpeech(true); $("#speech-consent").checked = false; updateSpeechButton(); });
$("#speech-summary").addEventListener("click", () => { stopCloudSpeech(true); $("#speech-text").value = pageSpeechSummary(); $("#speech-consent").checked = false; updateSpeechButton(); });
$("#device-speech").addEventListener("click", () => { stopCloudSpeech(); if (!("speechSynthesis" in window)) $("#speech-status").textContent = "Device speech is unavailable. Your text can still be shown or read with a screen reader."; else speak($("#speech-text").value); });
$("#clear-speech").addEventListener("click", () => { stopCloudSpeech(true); $("#speech-text").value = ""; $("#speech-consent").checked = false; $("#speech-status").textContent = "Message cleared."; if ("speechSynthesis" in window) window.speechSynthesis.cancel(); updateSpeechButton(); });
$("#access-dialog").addEventListener("close", () => { stopCloudSpeech(true); updateSpeechButton(); if ("speechSynthesis" in window) window.speechSynthesis.cancel(); });
document.addEventListener("visibilitychange", () => { if (document.hidden) { stopCloudSpeech(true); updateSpeechButton(); } });
$("#dictate").addEventListener("click", dictate);
$("#read-page").addEventListener("click", () => {
  if (!("speechSynthesis" in window)) { announce("Spoken output is unavailable. Use your screen reader or the text on this page."); return; }
  if (window.speechSynthesis.speaking) { window.speechSynthesis.cancel(); return; }
  const message = state.page === "wallet" ? `Your Faith demo tickets. ${state.bookings.length} tickets saved. ${state.bookings.map((b) => `${b.quote.offer.title}, ${humanDate(b.quote.offer.date)}, ${b.status.replaceAll("_", " ")}`).join(". ")}` : `Welcome to Faith. Search flights, trains, buses, cinema, and events. ${state.offers.length} demo options. ${state.offers.slice(0, 3).map((o) => `${o.title}, ${money((o.price_minor + o.fee_minor) * (state.search?.passengers || 1))} total`).join(". ")}. Choose Take a look to review an option. All tickets are fictional.`;
  speak(message);
});
$("#clear-filters").addEventListener("click", () => { $$(".chip input").forEach((input) => { input.checked = false; }); $("#budget").value = ""; searchTickets(); });
$("#wallet-list").addEventListener("click", (event) => {
  const download = event.target.closest("[data-download]"); if (download) downloadTicket(download.dataset.download);
  const cancel = event.target.closest("[data-cancel]"); if (cancel) { state.pendingCancel = cancel.dataset.cancel; openDialog("cancel-dialog"); }
});
$("#confirm-cancel").addEventListener("click", async (event) => {
  if (state.busy || !state.pendingCancel) return;
  state.busy = true; event.target.disabled = true;
  try { await api(`bookings/${encodeURIComponent(state.pendingCancel)}/cancel`, { method: "POST" }); $("#cancel-dialog").close(); await showWallet(); announce("Demo ticket cancelled. No payment was made or refunded.", true); }
  catch (error) { showError(error); }
  finally { state.busy = false; event.target.disabled = false; }
});
document.addEventListener("visibilitychange", () => { if (document.hidden) { stopDictation(); if (state.motion) disableMotion("Motion paused when you left the page. Enable it again when you’re ready."); if ("speechSynthesis" in window) window.speechSynthesis.cancel(); } });
window.addEventListener("pagehide", () => { stopDictation(); disableMotion(); });

applyPreferences();
(async () => {
  try { await api("session", { method: "POST" }); await searchTickets(true); await loadWallet(); }
  catch (error) { $("#results").setAttribute("aria-busy", "false"); $("#results").innerHTML = '<div class="loading-state">Faith couldn’t start a session. Refresh this page when your connection is ready.</div>'; showError(error); }
})();
