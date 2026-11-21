import { mountChrome, esc, $, fmtDate, toast, errMsg, applyI18n, t, IN_APP } from "./ui.js";
import { getUser, joinFixture, submitRoomCode, reportHostBlocked, openDispute, createHandoff, LIVE, fixtureBasics, getProfiles,
         uploadEvidence, myEvidence, evidenceUrl, reportPlayer } from "./api.js";
import { CONFIG } from "./config.js";

await mountChrome();
const room = $("#room");
const fid = new URLSearchParams(location.search).get("f") || "";
let tick = null, poll = null, target = null;

const NOTE = `<div class="notice"><b>Matches are played and verified in the WIN ZONE app.</b> Use this page to see your room code and timer, or to get back in if the app closes.</div>`;

function countdown(el, to, onZero) {
  clearInterval(tick); target = new Date(to).getTime();
  const step = () => {
    const s = Math.max(0, Math.round((target - Date.now()) / 1000));
    const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
    el.textContent = (hh ? hh + ":" : "") + String(mm).padStart(2, "0") + ":" + String(ss).padStart(2, "0");
    if (s === 0) { clearInterval(tick); onZero && onZero(); }
  };
  step(); tick = setInterval(step, 1000);
}

function show(html) { room.innerHTML = html + NOTE; applyI18n(room); }

async function copyCode(code) {
  try { await navigator.clipboard.writeText(code); toast("Code copied"); return; } catch (_) {}
  // Fallback for browsers that block the clipboard API: select the text and use the old command.
  try {
    const ta = document.createElement("textarea");
    ta.value = code; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.append(ta); ta.select(); document.execCommand("copy"); ta.remove();
    toast("Code copied");
  } catch (_) { toast("Press and hold the code to copy it"); }
}

// "Play game": ask the server for a one-time code, then open the app with it.
// The link carries the match id and that single-use 60-second code, never a login.
async function playGame(btn) {
  if (!IN_APP && !/Android/i.test(navigator.userAgent)) { toast("Open this page on your Android phone to play.", "err"); return; }
  btn.disabled = true;
  try {
    const r = await createHandoff(fid);
    if (!r.ok) {
      toast(({ too_early: "The room opens 2 minutes before kickoff.", fixture_closed: "This match is closed.", waiting_for_code: "The code is not ready yet." })[r.reason] || r.reason, "err");
      return;
    }
    if (IN_APP) { window.WinZoneApp.play(r.code); return; }   // inside the app: open the match screen directly
    const fallback = CONFIG.APK_URL || location.href;
    location.href = `intent://play?f=${encodeURIComponent(r.fixture_id)}&c=${encodeURIComponent(r.code)}#Intent;scheme=${CONFIG.APP_SCHEME};package=${CONFIG.APP_PACKAGE};S.browser_fallback_url=${encodeURIComponent(fallback)};end`;
  } catch (err) { toast(errMsg(err), "err"); }
  finally { setTimeout(() => { btn.disabled = false; }, 4000); }
}

async function load() {
  let r;
  try { r = await joinFixture(fid); } catch (e) { return show(`<h1>Matchroom</h1><div class="msg err">${esc(errMsg(e))}</div>`); }

  if (r.ok) {
    clearTimeout(poll); poll = setTimeout(load, 10000);
    show(`<h1 style="font-size:clamp(2.6rem,7vw,4.4rem)">Your match</h1>
      <div class="vs">You <i>VS</i> ${esc(r.opponent || "Opponent")}</div>
      <p class="mute">${esc(fmtDate(r.scheduled_at))}</p>
      <div class="code-label">Match code</div>
      <div class="room-code" id="the-code" aria-label="Match code">${esc(r.room_code)}</div>
      <div class="hero-actions" style="margin-top:14px">
        <button class="btn ghost" type="button" id="copy-code">Copy code</button>
        <button class="btn" type="button" id="play-btn">Play game</button>
      </div>
      <p class="small mute not-in-app" style="margin-top:14px">${esc(t("mr.appver"))} ${CONFIG.APK_URL ? `<a href="${esc(CONFIG.APK_URL)}" rel="noopener">${esc(t("mr.getapp"))}</a>` : ""}</p>
      <ol class="how-to">
        <li><b>Copy the code</b> above.</li>
        <li>Tap <b>Play game</b>. The WIN ZONE app opens and asks permission to record the screen.</li>
        <li>In the game, open the <b>private match</b> screen, paste the code and press <b>Search</b>. ${esc(r.opponent || "Your opponent")} does the same, and the game connects you.</li>
        <li>Play. The app reads the result and the bracket updates by itself.</li>
      </ol>
      <div id="problem"></div>`);

    $("#copy-code").addEventListener("click", () => copyCode(r.room_code));
    $("#play-btn").addEventListener("click", (e) => playGame(e.currentTarget));
    if (!problemOpen) renderProblem();
    return;
  }

  switch (r.reason) {
    case "too_early":
      show(`<h1 style="font-size:clamp(2.6rem,7vw,4.4rem)">Room opens soon</h1><p class="lede">Your room code appears 2 minutes before kickoff.</p>
        <div class="count" id="cd"></div><p class="mute">Kickoff ${esc(fmtDate(r.scheduled_at))}</p>`);
      countdown($("#cd"), r.reveal_at, load); break;
    case "waiting_for_host_code":
      clearTimeout(poll); poll = setTimeout(load, 4000);
      if (r.is_host) {
        show(`<h1 style="font-size:clamp(2.6rem,7vw,4.4rem)">You're the host</h1><p class="lede">Open the game, create the room, then the app reads the code. If it cannot, type it here.</p>
          <form id="code-form" class="form" style="max-width:420px"><div class="field"><label for="code">Room code</label><input id="code" maxlength="12" autocomplete="off" style="text-transform:uppercase;letter-spacing:.2em;font-size:1.4rem"></div>
          <button class="btn" type="submit">Submit code</button></form>
          <p class="mute small" style="margin-top:18px">Deadline: ${esc(fmtDate(r.checkin_deadline))}. <a href="#" id="blocked">I cannot create the room</a></p>`);
        $("#code-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          try { const x = await submitRoomCode(fid, $("#code").value.trim()); if (x.ok) { toast("Code shared with your opponent."); load(); } else toast(({ invalid_format: "That code format is not valid.", already_set_differently: "A different code is already set.", outside_submission_window: "Outside the allowed time." })[x.reason] || x.reason, "err"); }
          catch (err) { toast(errMsg(err), "err"); }
        });
        $("#blocked").addEventListener("click", async (e) => { e.preventDefault(); try { await reportHostBlocked(fid, "host reported being blocked"); toast("Reported. An admin will look at it."); } catch (err) { toast(errMsg(err), "err"); } });
      } else {
        show(`<h1 style="font-size:clamp(2.6rem,7vw,4.4rem)">Waiting for the host</h1><p class="lede">${esc(r.opponent || "Your opponent")} is creating the room. The code appears here the moment it is ready.</p>
          <p class="mute">Deadline: ${esc(fmtDate(r.checkin_deadline))}</p>`);
      }
      break;
    case "fixture_closed": show(`<h1>Match closed</h1><p class="lede">This match is finished or has been closed.</p><a class="btn" href="/me.html">My matches</a><div id="problem"></div>`); renderProblem(); break;
    case "not_scheduled": show(`<h1>Not scheduled yet</h1><p class="lede">The organizer has not set a time for this match.</p>`); break;
    default: show(`<h1>Matchroom</h1><p class="lede">You are not part of this match.</p><a class="btn" href="/me.html">My matches</a>`);
  }
}

// ---------------------------------------------------------------- problem with the match: note, screenshots, report the opponent
let problemOpen = false, probCache = null;
const reasonText = (r) => (t("r." + r) === "r." + r ? r : t("r." + r));
async function renderProblem(force = false) {
  const host = $("#problem");
  if (!host || !user) return;
  if (force || !probCache) {
    try {
      const f = await fixtureBasics(fid);
      if (!f || ![f.player_a_id, f.player_b_id].includes(user.id)) return;
      const oppId = f.player_a_id === user.id ? f.player_b_id : f.player_a_id;
      const opp = (await getProfiles([oppId]))[oppId] || null;
      const mine = await myEvidence(fid).catch(() => []);
      const urls = await Promise.all(mine.map((m) => evidenceUrl(m.path).catch(() => null)));
      probCache = { f, opp, mine: urls.filter(Boolean) };
    } catch (_) { return; }
  }
  const { f, opp, mine } = probCache;
  const recent = !f.completed_at || Date.now() - new Date(f.completed_at).getTime() < 3 * 86400000;
  host.innerHTML = `<details class="problem" id="prob-d"><summary>${esc(t("ev.title"))}</summary>
    ${recent ? `<form id="dispute" class="form" style="margin-top:16px">
      <p class="mute small">${esc(t("ev.lede"))}</p>
      <div class="field"><label for="d-note">${esc(t("ev.note"))}</label><textarea id="d-note" rows="3" maxlength="1000"></textarea></div>
      <div class="field"><label for="d-files">${esc(t("ev.files"))}</label><input id="d-files" type="file" accept="image/png,image/jpeg,image/webp" multiple></div>
      <div id="d-msg" role="alert"></div>
      <button class="btn ghost sm" type="submit">${esc(t("ev.send"))}</button></form>` : ""}
    ${mine.length ? `<div class="ev-list"><div class="code-label">${esc(t("ev.yours"))}</div><div class="ev-thumbs" id="ev-thumbs"></div></div>` : ""}
    ${opp && opp.username ? `<form id="report" class="form report-form" style="margin-top:22px">
      <h4 class="form-title">${esc(t("rep.title"))}: ${esc(opp.display_name || opp.username)}</h4>
      <div class="field"><label for="r-reason">${esc(t("rep.reason"))}</label><select id="r-reason">
        ${["cheating", "abuse", "no_show", "impersonation", "other"].map((k) => `<option value="${k}">${esc(t("rep." + k))}</option>`).join("")}</select></div>
      <div class="field"><label for="r-details">${esc(t("rep.details"))}</label><textarea id="r-details" rows="2" maxlength="1000"></textarea></div>
      <button class="btn ghost sm" type="submit">${esc(t("rep.send"))}</button></form>` : ""}
  </details>`;
  $("#prob-d").addEventListener("toggle", (e) => { problemOpen = e.target.open; });
  if (mine.length) $("#ev-thumbs").innerHTML = mine.map((u) => `<a href="${esc(u)}" target="_blank" rel="noopener"><img src="${esc(u)}" alt="Screenshot" loading="lazy"></a>`).join("");
  $("#dispute")?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = $("#d-msg"), btn = e.submitter; msg.innerHTML = "";
    const files = [...$("#d-files").files].slice(0, 5);
    if (btn) btn.disabled = true;
    try {
      if ($("#d-note").value.trim() || !files.length) await openDispute(fid, $("#d-note").value);
      for (const file of files) {
        msg.innerHTML = `<div class="msg ok">${esc(t("ev.uploading"))} ${esc(file.name)}</div>`;
        const r = await uploadEvidence(fid, user.id, file, $("#d-note").value.trim().slice(0, 300));
        if (!r.ok) throw new Error(reasonText(r.reason));
      }
      toast(t("ev.sent")); problemOpen = false; renderProblem(true);
    } catch (err) { msg.innerHTML = `<div class="msg err">${esc(errMsg(err))}</div>`; }
    finally { if (btn) btn.disabled = false; }
  });
  $("#report")?.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      const r = await reportPlayer(opp.username, $("#r-reason").value, $("#r-details").value, fid);
      if (!r.ok) throw new Error(reasonText(r.reason));
      toast(t("rep.sent")); e.target.reset();
    } catch (err) { toast(errMsg(err), "err"); }
  });
}

const user = await getUser().catch(() => null);
if (!fid) show(`<h1>Matchroom</h1><p class="lede">Open a match from <a href="/me.html">My matches</a>.</p>`);
else if (!user) location.replace(LIVE ? `/auth.html?next=${encodeURIComponent(location.pathname + location.search)}` : "/auth.html");
else load();
