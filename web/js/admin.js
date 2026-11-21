import { mountChrome, esc, $, $$, fmtDate, statusPill, toast, errMsg, t, nameOf, wallToUtc, utcToWall } from "./ui.js";
import { parseBrief } from "./describe.js";
import { LIVE, getUser, isOrganizer, isAdmin, listManaged, createTournament, setTournamentStatus, generateTournament, publishTournament,
         reopenRegistration, updateTournament, rescheduleFixture, editableFixtures, getProfiles, listCountries, listAdmins, addRole, removeRole,
         resolveFixture, listAttention, evidenceUrl, listReports, reviewReport, banPlayer, unbanPlayer, listBanned, setCountryBlocked,
         createDemo, deleteDemo, allSponsors, saveSponsor, deleteSponsor, setSponsorPlacement, uploadSponsorLogo } from "./api.js";

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
  await Promise.all([loadManaged(), admin ? loadAttention() : null, admin ? loadAdmins() : null,
    admin ? loadReports() : null, admin ? loadBans() : null, admin ? loadSponsors() : null, admin ? loadCountries() : null]);
  if (admin) $("#demo-card").hidden = false;
}
const say = (el, text, kind = "err") => { el.innerHTML = text ? `<div class="msg ${kind}"></div>` : ""; if (text) el.firstChild.textContent = text; };

// ---------------------------------------------------------------- create
const FORMAT_NAMES = { league: "League", league_knockout: "League + knockout", groups_knockout: "Groups + knockout", league_phase: "League phase + knockout", knockout: "Knockout only" };
// same rule as the server's recommend_format(): research in docs/RESEARCH.md
const recommend = (n) => (n <= 6 ? "league" : n <= 11 ? "league_knockout" : n <= 31 ? "groups_knockout" : "league_phase");

function wireForm() {
  const name = $("#n-name"), slug = $("#n-slug"), fmt = $("#n-format"), size = $("#n-size");
  let touched = false, fmtTouched = false;
  const hint = () => { $("#n-url").textContent = slug.value ? `${location.origin}/t/${slug.value}` : ""; };
  const syncFormat = () => {
    const rec = recommend(Number(size.value) || 2);
    if (!fmtTouched) fmt.value = rec;
    $("#n-rec").textContent = `Recommended for ${size.value || "?"} players: ${FORMAT_NAMES[rec]}`;
    $("#n-adv-w").hidden = fmt.value !== "league_knockout";
    $("#n-rounds-w").hidden = fmt.value !== "league_phase";
  };
  slug.addEventListener("input", () => { touched = true; hint(); });
  name.addEventListener("input", () => { if (!touched) { slug.value = name.value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""); hint(); } });
  size.addEventListener("input", syncFormat);
  fmt.addEventListener("change", () => { fmtTouched = true; syncFormat(); });
  syncFormat();

  // "Describe it": read the text, fill the form, show what was understood and what was assumed
  $("#read-brief").addEventListener("click", () => {
    const { draft, found } = parseBrief($("#brief").value);
    const pad = (n) => String(n).padStart(2, "0");
    const local = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
    if (draft.name) { name.value = draft.name; slug.value = draft.slug; touched = true; hint(); }
    size.value = draft.size;
    fmt.value = draft.format; fmtTouched = found.format;
    if (draft.advance) $("#n-adv").value = String(draft.advance);
    if (draft.rounds) $("#n-rounds").value = String(draft.rounds);
    $("#n-speed").value = draft.speed;
    $("#n-start").value = draft.starts_at ? local(draft.starts_at) : "";
    $("#n-prize").value = draft.prize;
    syncFormat();
    const row = (label, value, ok) => `<li><b>${esc(label)}:</b> ${esc(value)} <span class="mute small">${ok ? "· read from your text" : "· assumed, please check"}</span></li>`;
    $("#brief-out").innerHTML = `<ul class="brief-list">
      ${row("Name", draft.name || "(missing)", found.name)}
      ${row("Players", draft.size, found.size)}
      ${row("Format", FORMAT_NAMES[draft.format] + (found.format ? "" : " (recommended for this size)"), found.format)}
      ${draft.format === "league_knockout" ? row("Players who advance", draft.advance || 4, found.advance) : ""}
      ${draft.format === "league_phase" ? row("Matches per player", draft.rounds || "automatic", found.rounds) : ""}
      ${row("Starts", draft.starts_at ? draft.starts_at.toLocaleString() : "not set", found.starts)}
      ${row("Speed", { standard: "Standard (48 h)", fast: "Fast (24 h)", oneday: "One-day (45 min)" }[draft.speed], found.speed)}
      ${row("Prize", draft.prize || "none", found.prize)}</ul>
      <p class="mute small">The form below is filled in. Change anything, then press Create.</p>`;
    $("#n-name").scrollIntoView({ behavior: "smooth", block: "center" });
  });

  $("#new-t").addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = $("#n-msg"); say(msg, "");
    try {
      const tid = await createTournament({ name: name.value.trim(), slug: slug.value.trim(), format: fmt.value, size: Number(size.value),
        starts_at: $("#n-start").value ? new Date($("#n-start").value).toISOString() : null, prize: $("#n-prize").value.trim(), advance: Number($("#n-adv").value) });
      const patch = { schedule_speed: $("#n-speed").value };
      if (fmt.value === "league_phase" && $("#n-rounds").value) patch.phase_rounds = Number($("#n-rounds").value);
      const r = await updateTournament(tid, patch);
      if (!r.ok) throw new Error(r.reason);
      if ($("#n-open").checked) await setTournamentStatus(tid, "open");
      toast($("#n-open").checked ? "Tournament created and open for registration" : "Tournament created as a draft");
      $("#brief-out").innerHTML = ""; $("#brief").value = ""; e.target.reset(); touched = false; fmtTouched = false; hint(); syncFormat(); await loadManaged();
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
      <div class="row2"><div class="field"><label>Format</label><select name="format" ${open ? "" : "disabled"}>${Object.entries(FORMAT_NAMES).map(([k, v]) => `<option value="${k}" ${k === x.format ? "selected" : ""}>${esc(v)}</option>`).join("")}</select></div>
        <div class="field"><label>Speed</label><select name="speed">${[["standard", "Standard (48 h)"], ["fast", "Fast (24 h)"], ["oneday", "One-day (45 min)"]].map(([k, v]) => `<option value="${k}" ${k === x.schedule_speed ? "selected" : ""}>${v}</option>`).join("")}</select></div></div>
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
    <header><div><b>${esc(x.name)}</b>${x.is_demo ? ` <span class="pill demo">Demo</span>` : ""}<div class="mute small">${esc(t("fm." + x.format))} · ${x.entries?.[0]?.count ?? 0}/${x.size} players · <a href="/t/${encodeURIComponent(x.slug)}">/t/${esc(x.slug)}</a></div></div>${statusPill(x.status)}</header>
    <div class="a-body" data-body></div></div>`).join("");

  for (const x of list) {
    const body = $(`[data-id="${x.id}"] [data-body]`);
    const players = x.entries?.[0]?.count ?? 0;
    let html = "";
    if (x.is_demo) {
      html = `<p class="mute small">Demo played by bots. Real players cannot join and nothing counts in rankings.</p>
        <div class="a-actions"><a class="btn sm ghost" href="/t/${encodeURIComponent(x.slug)}">Watch it</a><button class="btn sm ghost" data-act="deldemo">Delete demo</button></div>`;
      body.innerHTML = html; continue;
    }
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
      if (act === "deldemo") { if (!confirm("Delete this demo tournament?")) return; const r = await deleteDemo(x.id); if (!r.ok) throw new Error(r.reason); toast("Demo deleted"); }
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
    if (v("speed").value !== x.schedule_speed) patch.schedule_speed = v("speed").value;
    if (!v("format").disabled && v("format").value !== x.format) patch.format = v("format").value;
    try {
      const r = await updateTournament(x.id, patch);
      if (!r.ok) throw new Error(({ format_locked: "The format is locked once fixtures exist.", unknown_speed: "Unknown speed.", size_below_players: "That is fewer than the players already registered.", size_locked: "The size is locked once fixtures exist.", unknown_time_zone: "Unknown time zone." })[r.reason] || r.reason);
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
  const { fixtures, reasons, profiles, notes, evidence } = await listAttention();
  $("#attention-card").hidden = false;
  $("#attention").innerHTML = fixtures.length ? fixtures.map((f) => `<div class="att" data-f="${f.id}">
    <div><b>${esc(nameOf(profiles, f.player_a_id))} v ${esc(nameOf(profiles, f.player_b_id))}</b>
      <small>${esc(f.tournament?.name || "")} · ${esc(f.stage)} round ${f.round} · ${esc(REASONS[reasons[f.id]] || reasons[f.id] || (f.status === "completed" ? `finished ${f.score_a ?? ""}–${f.score_b ?? ""}, a player asked for a check` : f.status))}</small>
      ${(notes[f.id] || []).filter((n) => n.note && n.note !== "Evidence added").map((n) => `<p class="att-note"><b>${esc(nameOf(profiles, n.user_id))}:</b> ${esc(n.note)}</p>`).join("")}
      ${(evidence[f.id] || []).length ? `<div class="ev-thumbs" data-ev='${esc(JSON.stringify((evidence[f.id] || []).map((e) => e.path)))}'></div>` : ""}</div>
    <div class="a-actions"><button class="btn sm" data-o="win_player_a">A wins</button><button class="btn sm" data-o="win_player_b">B wins</button>
      <button class="btn sm ghost" data-o="replay">Replay</button><button class="btn sm ghost" data-o="cancel">Cancel</button></div></div>`).join("")
    : `<div class="att"><span class="mute">Nothing needs a decision.</span></div>`;
  $$("[data-ev]").forEach(async (box) => {
    const paths = JSON.parse(box.dataset.ev);
    const urls = await Promise.all(paths.map((p) => evidenceUrl(p).catch(() => null)));
    box.innerHTML = urls.filter(Boolean).map((u) => `<a href="${esc(u)}" target="_blank" rel="noopener"><img src="${esc(u)}" alt="Evidence screenshot" loading="lazy"></a>`).join("");
  });
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

// ---------------------------------------------------------------- player reports
const REPORT_REASONS = { cheating: "Cheating", abuse: "Abuse or insults", impersonation: "Impersonation", no_show: "Did not show up", other: "Other" };
let reportFilter = "open";
async function loadReports() {
  $("#reports-card").hidden = false;
  const rows = await listReports(reportFilter || null);
  $("#reports").innerHTML = rows.length ? rows.map((r) => `<div class="att" data-r="${r.id}" data-user="${esc(r.reported)}">
      <div><b><a href="/p/${encodeURIComponent(r.reported)}">${esc(r.reported)}</a></b> <span class="pill">${esc(REPORT_REASONS[r.reason] || r.reason)}</span>
        ${r.reports_against > 1 ? `<span class="pill live">${r.reports_against} reports</span>` : ""}
        ${r.reported_banned_until ? `<span class="pill">suspended</span>` : ""}
        <small>by ${esc(r.reporter || "?")} · ${esc(fmtDate(r.created_at))}${r.fixture_id ? " · about a match" : ""} · ${esc(r.status)}</small>
        ${r.details ? `<p class="att-note">${esc(r.details)}</p>` : ""}</div>
      ${r.status === "open" ? `<div class="a-actions"><button class="btn sm" data-ban="7">Suspend 7 days</button><button class="btn sm ghost" data-ban="">Suspend permanently</button>
        <button class="btn sm ghost" data-rv="dismissed">Dismiss</button></div>` : ""}</div>`).join("")
    : `<div class="att"><span class="mute">${reportFilter ? "No open reports." : "No reports yet."}</span></div>`;
  $$("[data-rv]", $("#reports")).forEach((b) => b.addEventListener("click", async () => {
    try { await reviewReport(b.closest("[data-r]").dataset.r, b.dataset.rv); toast("Report closed"); await loadReports(); } catch (err) { toast(errMsg(err), "err"); }
  }));
  $$("[data-ban]", $("#reports")).forEach((b) => b.addEventListener("click", async () => {
    const row = b.closest("[data-r]"), days = b.dataset.ban ? Number(b.dataset.ban) : null;
    const reason = prompt(`Suspend ${row.dataset.user} ${days ? `for ${days} days` : "permanently"}. Reason (recorded, not shown to the player):`);
    if (!reason) return;
    try {
      const r = await banPlayer(row.dataset.user, days, reason);
      if (!r.ok) throw new Error(({ remove_admin_role_first: "Remove their admin role first.", cannot_ban_self: "You cannot suspend yourself." })[r.reason] || r.reason);
      await reviewReport(row.dataset.r, "actioned");
      toast("Player suspended"); await Promise.all([loadReports(), loadBans()]);
    } catch (err) { toast(errMsg(err), "err"); }
  }));
}
$$("[data-rs]").forEach((b) => b.addEventListener("click", () => {
  reportFilter = b.dataset.rs; $$("[data-rs]").forEach((x) => x.setAttribute("aria-pressed", String(x === b))); loadReports().catch((e) => toast(errMsg(e), "err"));
}));

// ---------------------------------------------------------------- suspensions
async function loadBans() {
  $("#bans-card").hidden = false;
  const rows = await listBanned();
  $("#bans").innerHTML = rows.length ? rows.map((r) => `<div class="adm-row">
      <div><b>${esc(r.username)}</b><small>${new Date(r.until).getFullYear() > 9000 || !isFinite(new Date(r.until)) ? "Permanent" : "Until " + esc(fmtDate(r.until))}${r.reason ? " · " + esc(r.reason) : ""}</small></div>
      <span></span><button class="btn sm ghost" data-unban="${esc(r.username)}">Lift</button></div>`).join("")
    : `<div class="att"><span class="mute">Nobody is suspended.</span></div>`;
  $$("[data-unban]").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm(`Lift the suspension of ${b.dataset.unban}?`)) return;
    try { await unbanPlayer(b.dataset.unban); toast("Suspension lifted"); await loadBans(); } catch (err) { toast(errMsg(err), "err"); }
  }));
}
$("#ban-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#bn-msg"); say(msg, "");
  try {
    const r = await banPlayer($("#bn-user").value.trim(), $("#bn-days").value ? Number($("#bn-days").value) : null, $("#bn-reason").value);
    if (!r.ok) throw new Error(({ player_not_found: "No player with that username.", remove_admin_role_first: "Remove their admin role first.", cannot_ban_self: "You cannot suspend yourself." })[r.reason] || r.reason);
    toast(`Suspended. Left ${r.left_tournaments} open tournament(s).`); e.target.reset(); await loadBans();
  } catch (err) { say(msg, errMsg(err)); }
});

// ---------------------------------------------------------------- demo
$("#demo-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#dm-msg"); say(msg, "");
  try {
    const r = await createDemo($("#dm-name").value.trim(), Number($("#dm-size").value), $("#dm-format").value);
    if (!r.ok) throw new Error(r.reason);
    msg.innerHTML = `<div class="msg ok">Demo created. <a href="/t/${encodeURIComponent(r.slug)}">Open it</a>. The first matches are played within a few minutes.</div>`;
    await loadManaged();
  } catch (err) { say(msg, errMsg(err)); }
});

// ---------------------------------------------------------------- sponsors
const PLACE = { title: "Title sponsor", bracket_logo: "Bracket partner", round: "Round partner", prize: "Prize partner" };
let sponsorCache = [], tournamentCache = [];
async function loadSponsors() {
  $("#sponsors-card").hidden = false;
  [sponsorCache, tournamentCache] = await Promise.all([allSponsors(), listManaged()]);
  const tname = (id) => tournamentCache.find((x) => x.id === id)?.name || "(deleted tournament)";
  const options = tournamentCache.filter((x) => !["completed", "cancelled"].includes(x.status)).map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join("");
  $("#sponsors").innerHTML = sponsorCache.length ? sponsorCache.map((s) => `<div class="sp-admin" data-s="${s.id}">
      <div class="sp-admin-head">
        <span class="sp-logo sm">${s.logo_url ? `<img src="${esc(s.logo_url)}" alt="">` : `<span>${esc(s.name)}</span>`}</span>
        <div><b>${esc(s.name)}</b><small>${s.website ? esc(s.website) : "No website"} · ${s.active ? "active" : "paused"}${s.show_on_home ? " · on home page" : ""}</small></div>
        <div class="a-actions"><button class="btn sm ghost" data-sedit>Edit</button><button class="btn sm ghost" data-sdel>Delete</button></div></div>
      <div class="sp-places">${(s.placements || []).map((p) => `<span class="chip">${esc(PLACE[p.placement_type])}: ${esc(tname(p.tournament_id))}
          <button type="button" aria-label="Remove" data-unplace="${p.tournament_id}|${p.placement_type}">×</button></span>`).join("")}</div>
      ${options ? `<div class="sp-place-form"><select data-pt>${options}</select><select data-pk>${Object.entries(PLACE).map(([k, v]) => `<option value="${k}">${v}</option>`).join("")}</select>
        <button class="btn sm" type="button" data-place>Place</button></div>` : ""}</div>`).join("")
    : `<div class="att"><span class="mute">No sponsors yet.</span></div>`;
  $$("[data-s]", $("#sponsors")).forEach((row) => {
    const s = sponsorCache.find((x) => x.id === row.dataset.s);
    $("[data-sedit]", row).addEventListener("click", () => {
      $("#sp-id").value = s.id; $("#sp-name").value = s.name; $("#sp-web").value = s.website || ""; $("#sp-logo").value = s.logo_url || "";
      $("#sp-active").checked = s.active; $("#sp-home").checked = s.show_on_home; $("#sp-save").textContent = "Save sponsor"; $("#sp-cancel").hidden = false;
      $("#sp-name").focus();
    });
    $("[data-sdel]", row).addEventListener("click", async () => {
      if (!confirm(`Delete ${s.name} and all its placements?`)) return;
      try { await deleteSponsor(s.id); toast("Sponsor deleted"); await loadSponsors(); } catch (err) { toast(errMsg(err), "err"); }
    });
    $("[data-place]", row)?.addEventListener("click", async () => {
      try { await setSponsorPlacement($("[data-pt]", row).value, s.id, $("[data-pk]", row).value, true); toast("Placed"); await loadSponsors(); } catch (err) { toast(errMsg(err), "err"); }
    });
    $$("[data-unplace]", row).forEach((b) => b.addEventListener("click", async () => {
      const [tid, type] = b.dataset.unplace.split("|");
      try { await setSponsorPlacement(tid, s.id, type, false); await loadSponsors(); } catch (err) { toast(errMsg(err), "err"); }
    }));
  });
}
function resetSponsorForm() { $("#sp-form").reset(); $("#sp-id").value = ""; $("#sp-save").textContent = "Add sponsor"; $("#sp-cancel").hidden = true; }
$("#sp-cancel")?.addEventListener("click", resetSponsorForm);
$("#sp-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#sp-msg"); say(msg, "");
  try {
    let logo = $("#sp-logo").value.trim();
    const file = $("#sp-file").files[0];
    if (file) logo = await uploadSponsorLogo(file);
    const r = await saveSponsor({ id: $("#sp-id").value || null, name: $("#sp-name").value.trim(), website: $("#sp-web").value.trim(), logo_url: logo,
      active: $("#sp-active").checked, show_on_home: $("#sp-home").checked });
    if (!r.ok) throw new Error(({ links_must_start_with_https: "Links must start with https://", name_required: "Enter a name." })[r.reason] || r.reason);
    toast("Sponsor saved"); resetSponsorForm(); await loadSponsors();
  } catch (err) { say(msg, errMsg(err)); }
});

// ---------------------------------------------------------------- countries
async function loadCountries() {
  $("#countries-card").hidden = false;
  const list = await listCountries();
  const blocked = list.filter((c) => c.blocked);
  $("#blocked").innerHTML = blocked.length ? blocked.map((c) => `<div class="adm-row"><div><b>${esc(c.name)}</b><small>Blocked</small></div><span></span>
      <button class="btn sm ghost" data-unblock="${c.code}">Unblock</button></div>`).join("")
    : `<div class="att"><span class="mute">Tournaments are open in every listed country.</span></div>`;
  $("#cty").innerHTML = list.filter((c) => !c.blocked).map((c) => `<option value="${c.code}">${esc(c.name)}</option>`).join("");
  $$("[data-unblock]").forEach((b) => b.addEventListener("click", async () => {
    try { await setCountryBlocked(b.dataset.unblock, false); toast("Unblocked"); await loadCountries(); } catch (err) { toast(errMsg(err), "err"); }
  }));
}
$("#cty-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const sel = $("#cty");
  if (!confirm(`Block ${sel.options[sel.selectedIndex].text}? Players there will not be able to register.`)) return;
  try { await setCountryBlocked(sel.value, true); toast("Blocked"); await loadCountries(); } catch (err) { toast(errMsg(err), "err"); }
});

start();
