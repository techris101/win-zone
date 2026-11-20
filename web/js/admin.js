import { mountChrome, esc, $, $$, fmtDate, statusPill, toast, errMsg, t } from "./ui.js";
import { LIVE, getUser, isOrganizer, isAdmin, listManaged, createTournament, setTournamentStatus, generateTournament,
         scheduleFixtures, resolveFixture, listAttention, sb } from "./api.js";
import { nameOf } from "./ui.js";

await mountChrome();
const gate = $("#admin-gate"), main = $("#admin-main");

async function start() {
  if (!LIVE) { gate.textContent = "Connect the live service to use the organizer panel."; return; }
  const user = await getUser().catch(() => null);
  if (!user) return location.replace("/auth.html?next=/admin.html");
  if (!(await isOrganizer())) { gate.textContent = "Organizer access is required. Ask an admin to grant it."; return; }
  gate.hidden = true; main.hidden = false;
  wireForm();
  await Promise.all([loadManaged(), (await isAdmin()) ? loadAttention() : null]);
}

// ---------------------------------------------------------------- create
function wireForm() {
  const name = $("#n-name"), slug = $("#n-slug"), fmt = $("#n-format");
  let touched = false;
  slug.addEventListener("input", () => { touched = true; hint(); });
  name.addEventListener("input", () => { if (!touched) { slug.value = name.value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""); hint(); } });
  const hint = () => { $("#n-url").textContent = slug.value ? `${location.origin}/t/${slug.value}` : ""; };
  fmt.addEventListener("change", () => { $("#n-adv-w").hidden = fmt.value !== "league_knockout"; });
  $("#new-t").addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = $("#n-msg"); msg.innerHTML = "";
    try {
      await createTournament({ name: name.value.trim(), slug: slug.value.trim(), format: fmt.value, size: Number($("#n-size").value),
        starts_at: $("#n-start").value ? new Date($("#n-start").value).toISOString() : null, prize: $("#n-prize").value.trim(), advance: Number($("#n-adv").value) });
      toast("Tournament created"); e.target.reset(); touched = false; hint(); await loadManaged();
    } catch (err) { msg.innerHTML = `<div class="msg err"></div>`; msg.firstChild.textContent = /duplicate/.test(err.message) ? "That link name is taken." : errMsg(err); }
  });
}

// ---------------------------------------------------------------- tournaments
async function pendingRounds(tid) {
  const c = await sb();
  const { data, error } = await c.from("fixtures").select("stage,round,scheduled_at,player_a_id,player_b_id,status").eq("tournament_id", tid).eq("status", "scheduled");
  if (error) throw new Error(error.message);
  const map = new Map();
  for (const f of data) {
    if (!f.player_a_id || !f.player_b_id || f.scheduled_at) continue;
    const k = `${f.stage}:${f.round}`; map.set(k, { stage: f.stage, round: f.round, n: (map.get(k)?.n || 0) + 1 });
  }
  return [...map.values()].sort((a, b) => a.stage.localeCompare(b.stage) || a.round - b.round);
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
    if (x.status === "draft") {
      body.innerHTML = `<div class="a-actions"><button class="btn sm" data-act="open">Open registration</button></div>`;
    } else if (x.status === "open") {
      body.innerHTML = `<div class="a-actions"><button class="btn sm" data-act="generate">Close registration and generate bracket</button><button class="btn sm ghost" data-act="draft">Back to draft</button></div>
        <p class="mute small">Players are seeded at random. This cannot be undone.</p>`;
    } else if (x.status === "live") {
      let rounds = [];
      try { rounds = await pendingRounds(x.id); } catch (_) {}
      body.innerHTML = rounds.length ? rounds.map((r) => `<form class="row2" data-sched data-stage="${r.stage}" data-round="${r.round}" style="align-items:end">
          <div class="field"><label>${esc(r.stage)} round ${r.round} · ${r.n} fixtures</label><input type="datetime-local" required></div>
          <div class="a-actions"><input type="number" min="5" max="240" value="30" aria-label="Minutes between fixtures" style="width:90px;background:var(--bg);border:1px solid var(--line);color:var(--fg);padding:13px">
          <button class="btn sm" type="submit">Schedule</button></div></form>`).join("") : `<p class="mute">Everything playable is scheduled.</p>`;
    } else body.innerHTML = `<p class="mute">No actions.</p>`;
  }
  $$("[data-act]").forEach((b) => b.addEventListener("click", async () => {
    const tid = b.closest("[data-id]").dataset.id, act = b.dataset.act;
    try {
      if (act === "open") await setTournamentStatus(tid, "open");
      if (act === "draft") await setTournamentStatus(tid, "draft");
      if (act === "generate") { if (!confirm("Generate the bracket now? Registration closes and seeding is random.")) return; const r = await generateTournament(tid); toast(`Bracket generated for ${r.players} players`); }
      await loadManaged();
    } catch (err) { toast(errMsg(err), "err"); }
  }));
  $$("[data-sched]").forEach((f) => f.addEventListener("submit", async (e) => {
    e.preventDefault();
    const tid = f.closest("[data-id]").dataset.id;
    try {
      const n = await scheduleFixtures(tid, f.dataset.stage, Number(f.dataset.round), new Date($("input[type=datetime-local]", f).value).toISOString(), Number($("input[type=number]", f).value));
      toast(`${n} fixtures scheduled`); await loadManaged();
    } catch (err) { toast(errMsg(err), "err"); }
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

start();
void fmtDate;
