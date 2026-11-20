import { mountChrome, esc, $, $$, fmtDate, statusPill, toast, errMsg, t, nameOf, wallToUtc, utcToWall } from "./ui.js";
import { LIVE, getUser, isOrganizer, isAdmin, listManaged, createTournament, setTournamentStatus, generateTournament, publishTournament,
         reopenRegistration, updateTournament, rescheduleFixture, editableFixtures, getProfiles, listCountries, listAdmins, addRole, removeRole,
         resolveFixture, listAttention } from "./api.js";

await mountChrome();
const gate = $("#admin-gate"), main = $("#admin-main");
let me = null, zones = ["UTC"];

async function start() {
  if (!LIVE) { gate.textContent = "Connect the live service to use the organizer panel."; return; }
  me = await getUser().catch(() => null);
  if (!me) return location.replace("/auth.html?next=/admin.html");
  if (!(await isOrganizer())) { gate.textContent = "Organizer access is required. Ask an admin to grant it."; return; }
  gate.hidden = true; main.hidden = false;
  try { zones = [...new Set([...(await listCountries()).map((c) => c.tz), "UTC"])].sort(); } catch (_) {}
  wireForm();
  await loadAll();
}
async function loadAll() {
  const admin = await isAdmin();
  await Promise.all([loadManaged(), admin ? loadAttention() : null, admin ? loadAdmins() : null]);
}
const say = (el, text, kind = "err") => { el.innerHTML = text ? `<div class="msg ${kind}"></div>` : ""; if (text) el.firstChild.textContent = text; };

// ---------------------------------------------------------------- create
function wireForm() {
  const name = $("#n-name"), slug = $("#n-slug"), fmt = $("#n-format");
  let touched = false;
  const hint = () => { $("#n-url").textContent = slug.value ? `${location.origin}/t/${slug.value}` : ""; };
  slug.addEventListener("input", () => { touched = true; hint(); });
  name.addEventListener("input", () => { if (!touched) { slug.value = name.value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""); hint(); } });
  fmt.addEventListener("change", () => { $("#n-adv-w").hidden = fmt.value !== "league_knockout"; });
  $("#new-t").addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = $("#n-msg"); say(msg, "");
    try {
      await createTournament({ name: name.value.trim(), slug: slug.value.trim(), format: fmt.value, size: Number($("#n-size").value),
        starts_at: $("#n-start").value ? new Date($("#n-start").value).toISOString() : null, prize: $("#n-prize").value.trim(), advance: Number($("#n-adv").value) });
      toast("Tournament created"); e.target.reset(); touched = false; hint(); await loadManaged();
    } catch (err) { say(msg, /duplicate/.test(err.message) ? "That link name is taken." : errMsg(err)); }
  });
}

// ---------------------------------------------------------------- tournaments
const tzOf = (x) => x.schedule_tz || "Africa/Kigali";

function settingsForm(x) {
  const open = x.status === "draft" || x.status === "open";
  return `<details class="a-set"><summary>Settings and schedule rules</summary>
    <form data-settings class="form" style="margin-top:14px">
      <div class="row2"><div class="field"><label>Name</label><input name="name" value="${esc(x.name)}" maxlength="60" required></div>
        <div class="field"><label>Prize (non-cash)</label><input name="prize" value="${esc(x.prize_description || "")}" maxlength="120"></div></div>
      <div class="row2"><div class="field"><label>Max players</label><input name="size" type="number" min="2" max="128" value="${x.size}" ${open ? "" : "disabled"}></div>
        <div class="field"><label>Starts (in the schedule time zone)</label><input name="starts" type="datetime-local" value="${x.starts_at ? utcToWall(x.starts_at, tzOf(x)) : ""}"></div></div>
      <div class="row2"><div class="field"><label>Schedule time zone</label>
          <select name="tz"><option value="">Automatic (most common among players)</option>${zones.map((z) => `<option ${z === x.schedule_tz ? "selected" : ""}>${esc(z)}</option>`).join("")}</select></div>
        <div class="field"><label>Match time of day (hour, 0-23)</label><input name="hour" type="number" min="0" max="23" value="${x.slot_hour}"></div></div>
      <div class="row2"><div class="field"><label>Hours between rounds</label><input name="gap" type="number" min="1" max="720" value="${x.round_gap_hours}"></div>
        ${x.format === "league_knockout" ? `<div class="field"><label>Players who advance</label><select name="adv">${[2, 4, 8, 16].map((n) => `<option ${n === x.league_advance ? "selected" : ""}>${n}</option>`).join("")}</select></div>` : "<div></div>"}</div>
      <p class="mute small">Times are chosen automatically from these rules when the fixtures are prepared. You can still change any single match time.</p>
      <div data-msg role="alert"></div><button class="btn sm" type="submit">Save settings</button>
    </form></details>`;
}

async function fixtureEditor(x, host, onlyScheduled = true) {
  host.innerHTML = `<div class="mute small" style="padding:14px 20px">Loading fixtures…</div>`;
  const list = (await editableFixtures(x.id)).filter((f) => f.player_a_id && f.player_b_id && (!onlyScheduled || f.status === "scheduled"));
  const profiles = await getProfiles(list.flatMap((f) => [f.player_a_id, f.player_b_id]));
  if (!list.length) { host.innerHTML = `<div class="mute small" style="padding:14px 20px">No fixtures to edit.</div>`; return; }
  host.innerHTML = list.map((f) => `<div class="fx-edit" data-f="${f.id}">
      <div><b>${esc(nameOf(profiles, f.player_a_id))} v ${esc(nameOf(profiles, f.player_b_id))}</b>
        <small>${esc(f.stage)} round ${f.round} · now ${esc(fmtDate(f.scheduled_at))}</small></div>
      <input type="datetime-local" value="${f.scheduled_at ? utcToWall(f.scheduled_at, tzOf(x)) : ""}" aria-label="Match time in ${esc(tzOf(x))}">
      <button class="btn sm ghost" type="button" data-save>Save</button></div>`).join("")
    + `<div class="mute small" style="padding:10px 20px">Times you type are in <b>${esc(tzOf(x))}</b>.</div>`;
  $$("[data-save]", host).forEach((b) => b.addEventListener("click", async () => {
    const row = b.closest("[data-f]"), v = $("input", row).value;
    if (!v) return toast("Pick a time first.", "err");
    try {
      const r = await rescheduleFixture(row.dataset.f, wallToUtc(v, tzOf(x)).toISOString());
      if (!r.ok) throw new Error(r.reason);
      toast("Time saved"); await fixtureEditor(x, host, onlyScheduled);
    } catch (err) { toast(errMsg(err), "err"); }
  }));
}

async function loadManaged() {
  const list = await listManaged();
  const host = $("#managed");
  if (!list.length) { host.innerHTML = `<div class="empty">No tournaments yet. Create your first one.</div>`; return; }
  host.innerHTML = list.map((x) => `<div class="a-card" data-id="${x.id}">
    <header><div><b>${esc(x.name)}</b><div class="mute small">${esc(t("fm." + x.format))} · ${x.entries?.[0]?.count ?? 0}/${x.size} players · <a href="/t/${encodeURIComponent(x.slug)}">/t/${esc(x.slug)}</a></div></div>${statusPill(x.status)}</header>
    <div class="a-body" data-body></div></div>`).join("");

  for (const x of list) {
    const body = $(`[data-id="${x.id}"] [data-body]`);
    const players = x.entries?.[0]?.count ?? 0;
    let html = "";
    if (x.status === "draft") {
      html = `<div class="a-actions"><button class="btn sm" data-act="open">Open registration</button></div>`;
    } else if (x.status === "open") {
      html = `<p class="mute small">${players} of ${x.size} places taken. Registration closes by itself when the last place is taken, and a draft of the fixtures is prepared for you to review.</p>
        <div class="a-actions"><button class="btn sm" data-act="plan">Close now and prepare fixtures</button><button class="btn sm ghost" data-act="draft">Back to draft</button></div>`;
    } else if (x.status === "planning") {
      html = `<div class="notice" style="margin:0"><b>Draft fixtures.</b> Only you can see them. Change any time you like, then publish.</div>
        <div data-fx></div>
        <div class="a-actions"><button class="btn sm" data-act="publish">Publish fixtures</button><button class="btn sm ghost" data-act="reopen">Back to registration (deletes the draft)</button></div>`;
    } else if (x.status === "live") {
      html = `<details class="a-set"><summary>Upcoming fixtures and times</summary><div data-fx></div></details>`;
    } else html = `<p class="mute">No actions.</p>`;
    if (!["completed", "cancelled"].includes(x.status)) html += settingsForm(x);
    body.innerHTML = html;
    const fxHost = $("[data-fx]", body);
    if (fxHost && x.status === "planning") fixtureEditor(x, fxHost).catch((e) => { fxHost.textContent = errMsg(e); });
    const det = $("details.a-set", body);
    if (x.status === "live" && fxHost) det.addEventListener("toggle", () => { if (det.open) fixtureEditor(x, fxHost).catch((e) => { fxHost.textContent = errMsg(e); }); }, { once: true });
  }

  $$("[data-act]").forEach((b) => b.addEventListener("click", async () => {
    const x = list.find((i) => i.id === b.closest("[data-id]").dataset.id), act = b.dataset.act;
    try {
      if (act === "open") await setTournamentStatus(x.id, "open");
      if (act === "draft") await setTournamentStatus(x.id, "draft");
      if (act === "plan") {
        if (!confirm("Close registration now and prepare the fixtures? Players are seeded at random.")) return;
        const r = await generateTournament(x.id); if (!r.ok) throw new Error(r.reason === "need_two_players" ? "At least 2 players are needed." : r.reason);
        toast(`Draft prepared for ${r.players} players`);
      }
      if (act === "publish") {
        if (!confirm("Publish the fixtures? Everyone will see them and matchrooms will open at the set times.")) return;
        const r = await publishTournament(x.id); if (!r.ok) throw new Error(r.reason); toast("Published");
      }
      if (act === "reopen") {
        if (!confirm("Delete the draft fixtures and reopen registration?")) return;
        const r = await reopenRegistration(x.id); if (!r.ok) throw new Error(r.reason); toast("Registration reopened");
      }
      await loadManaged();
    } catch (err) { toast(errMsg(err), "err"); }
  }));

  $$("[data-settings]").forEach((f) => f.addEventListener("submit", async (e) => {
    e.preventDefault();
    const x = list.find((i) => i.id === f.closest("[data-id]").dataset.id), v = (n) => f.elements[n];
    const msg = $("[data-msg]", f); say(msg, "");
    const patch = { name: v("name").value.trim(), prize_description: v("prize").value.trim(), slot_hour: Number(v("hour").value), round_gap_hours: Number(v("gap").value) };
    if (v("tz").value) patch.schedule_tz = v("tz").value;
    patch.starts_at = v("starts").value ? wallToUtc(v("starts").value, v("tz").value || tzOf(x)).toISOString() : "";
    if (!v("size").disabled) patch.size = Number(v("size").value);
    if (v("adv")) patch.league_advance = Number(v("adv").value);
    try {
      const r = await updateTournament(x.id, patch);
      if (!r.ok) throw new Error(({ size_below_players: "That is fewer than the players already registered.", size_locked: "The size is locked once fixtures exist.", unknown_time_zone: "Unknown time zone." })[r.reason] || r.reason);
      toast("Saved"); await loadManaged();
    } catch (err) { say(msg, errMsg(err)); }
  }));
}

// ---------------------------------------------------------------- attention (admins)
const REASONS = { score_mismatch: "Phones reported different scores", clock_mismatch: "Phones disagree on full time", both_claim_forfeit: "Both phones show a quit",
  conflicting_terminals: "One phone shows a quit, the other a result", opponent_still_playing: "Quit claimed while the opponent kept playing",
  knockout_level_no_winner: "Knockout ended level with no penalties", knockout_level_at_regulation: "Knockout level at 90:00", clock_anomaly: "Unreadable full-time clock",
  host_blocked: "Host could not create the room", stalled: "Both phones went quiet" };

async function loadAttention() {
  const { fixtures, reasons, profiles } = await listAttention();
  $("#attention-card").hidden = false;
  $("#attention").innerHTML = fixtures.length ? fixtures.map((f) => `<div class="att" data-f="${f.id}">
    <div><b>${esc(nameOf(profiles, f.player_a_id))} v ${esc(nameOf(profiles, f.player_b_id))}</b>
      <small>${esc(f.tournament?.name || "")} · ${esc(f.stage)} round ${f.round} · ${esc(REASONS[reasons[f.id]] || reasons[f.id] || f.status)}</small></div>
    <div class="a-actions"><button class="btn sm" data-o="win_player_a">A wins</button><button class="btn sm" data-o="win_player_b">B wins</button>
      <button class="btn sm ghost" data-o="replay">Replay</button><button class="btn sm ghost" data-o="cancel">Cancel</button></div></div>`).join("")
    : `<div class="att"><span class="mute">Nothing needs a decision.</span></div>`;
  $$("[data-o]").forEach((b) => b.addEventListener("click", async () => {
    const notes = prompt("Reason for this decision (recorded in the audit log):");
    if (!notes) return;
    try { await resolveFixture(b.closest("[data-f]").dataset.f, b.dataset.o, notes); toast("Decision recorded"); await Promise.all([loadAttention(), loadManaged()]); }
    catch (err) { toast(errMsg(err), "err"); }
  }));
}

// ---------------------------------------------------------------- admins
async function loadAdmins() {
  $("#admins-card").hidden = false;
  const rows = await listAdmins();
  $("#admins-list").innerHTML = rows.map((r) => `<div class="adm-row">
      <div><b>${esc(r.username || "(no profile)")}</b><small>${esc(r.email || "")}</small></div>
      <span class="pill ${r.role === "admin" ? "open" : ""}">${esc(r.role)}</span>
      ${r.user_id === me.id ? `<span class="mute small">You</span>` : `<button class="btn sm ghost" data-rm="${r.user_id}" data-role="${r.role}">Remove</button>`}</div>`).join("");
  $$("[data-rm]").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm(`Remove this ${b.dataset.role}?`)) return;
    try {
      const r = await removeRole(b.dataset.rm, b.dataset.role);
      if (!r.ok) throw new Error(({ cannot_remove_yourself: "You cannot remove yourself.", last_admin: "There must always be one admin." })[r.reason] || r.reason);
      toast("Removed"); await loadAdmins();
    } catch (err) { toast(errMsg(err), "err"); }
  }));
}
$("#add-admin")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#ad-msg"); say(msg, "");
  try {
    const r = await addRole($("#ad-who").value, $("#ad-role").value);
    if (!r.ok) throw new Error(({ no_such_account: "No WIN ZONE account with that email or username. They need to register first.", bad_role: "Unknown role." })[r.reason] || r.reason);
    toast("Added"); e.target.reset(); await loadAdmins();
  } catch (err) { say(msg, errMsg(err)); }
});

start();
