import { mountChrome, esc, $, $$, fmtDate, statusPill, toast, errMsg, t, applyI18n, chooseCountryAndSave } from "./ui.js";
import { LIVE, getUser, getTournament, getTournamentData, subscribe, register, withdraw, myEntryIds, playerStats, leaders, sponsorsFor } from "./api.js";
import { renderBracket, renderTable, renderFixtures, renderPlayers, renderGroups, phaseZones, renderRace, renderLeaders } from "./bracket.js";
import { nameOf } from "./ui.js";

await mountChrome();
const root = $("#t-root");

const params = new URLSearchParams(location.search);
const slug = decodeURIComponent((location.pathname.match(/^\/t\/([^/]+)/) || [])[1] || params.get("s") || "");

let tour = null, data = null, user = null, joined = false, tab = null, sponsors = [];

async function boot() {
  if (!slug) return notFound();
  try { tour = await getTournament(slug); } catch (e) { root.innerHTML = `<div class="wrap"><div class="empty" style="margin:60px 0">${esc(errMsg(e))}</div></div>`; return; }
  if (!tour) return notFound();
  document.title = `${tour.name} — WIN ZONE`;
  user = await getUser().catch(() => null);
  if (user && LIVE) joined = (await myEntryIds(user.id).catch(() => new Set())).has(tour.id);
  sponsors = await sponsorsFor(tour.id).catch(() => []);
  await refresh(true);
  subscribe(tour.id, debounced).catch(() => {});
  setInterval(() => refresh(false), 30000);
}

function notFound() {
  root.innerHTML = `<div class="wrap prose"><span class="eyebrow">404</span><h1>Not found</h1><p class="lede">We could not find that tournament.</p><a class="btn" href="/">Back home</a></div>`;
}

let timer;
function debounced() { clearTimeout(timer); timer = setTimeout(() => refresh(false), 400); }

async function refresh(first) {
  try {
    const fresh = await getTournament(slug);
    if (fresh) tour = fresh;
    data = await getTournamentData(tour);
  } catch (e) { if (first) toast(errMsg(e), "err"); return; }
  render(first);
}

const hasKnockout = () => data.fixtures.some((f) => f.stage === "knockout" || f.stage === "playoff");
function tabsFor() {
  const out = [];
  if (tour.format === "groups_knockout") out.push(["groups", "t.groups"]);
  if (tour.format !== "league") out.push(["bracket", "t.bracket"]);
  if (["league", "league_knockout", "league_phase"].includes(tour.format)) out.push(["table", "t.table"]);
  out.push(["stats", "t.stats"], ["fixtures", "t.fixtures"], ["players", "t.players"]);
  return out;
}

function render() {
  const tabs = tabsFor();
  if (!tab || !tabs.some(([k]) => k === tab)) {
    tab = tour.format === "knockout" ? "bracket" : tour.format === "league" ? "table"
      : hasKnockout() ? "bracket" : tour.format === "groups_knockout" ? "groups" : "table";
  }
  const players = tour.entries?.[0]?.count ?? data.entries.length;
  const champ = tour.champion_id ? nameOf(data.profiles, tour.champion_id) : null;
  const full = players >= tour.size;
  const canRegister = tour.status === "open" && !tour.is_demo;
  const title = sponsors.find((x) => x.placement_type === "title");
  const others = sponsors.filter((x) => x.placement_type !== "title");
  const sp = (x) => { const s = x.sponsor; const inner = s.logo_url ? `<img src="${esc(s.logo_url)}" alt="${esc(s.name)}" loading="lazy">` : `<span>${esc(s.name)}</span>`;
    return s.website ? `<a class="sp-logo" href="${esc(s.website)}" target="_blank" rel="noopener sponsored">${inner}</a>` : `<span class="sp-logo">${inner}</span>`; };

  root.innerHTML = `
    <section class="t-head"><div class="wrap">
      ${statusPill(tour.status)}${tour.is_demo ? ` <span class="pill demo">${esc(t("t.demo"))}</span>` : ""}
      <h1 style="margin-top:16px">${esc(tour.name)}</h1>
      ${title ? `<div class="presented"><span>${esc(t("sp.presented"))}</span>${sp(title)}</div>` : ""}
      ${tour.is_demo ? `<p class="mute small demo-note">${esc(t("t.demonote"))}</p>` : ""}
      <dl class="facts">
        <div class="fact"><dt>${t("t.format")}</dt><dd>${esc(t("fm." + tour.format))}</dd></div>
        <div class="fact"><dt>${t("t.size")}</dt><dd class="num">${players} / ${tour.size}</dd></div>
        <div class="fact"><dt>${t("t.entry")}</dt><dd>${t("t.free")}</dd></div>
        ${tour.prize_description ? `<div class="fact"><dt>${t("t.prize")}</dt><dd>${esc(tour.prize_description)}</dd></div>` : ""}
        ${tour.starts_at ? `<div class="fact"><dt>${t("t.starts")}</dt><dd>${esc(fmtDate(tour.starts_at))}</dd></div>` : ""}
      </dl>
      <div class="t-actions" id="actions"></div>
      ${others.length ? `<div class="sp-strip"><span class="k">${esc(t("sp.partners"))}</span>${others.map(sp).join("")}</div>` : ""}
      ${champ ? `<div class="champion"><div><div class="k">${t("t.champion")}</div><div class="v">${esc(champ)}</div></div></div>` : ""}
    </div></section>
    <div class="wrap">
      <div class="tabs" role="tablist">${tabs.map(([k, label]) => `<button role="tab" data-tab="${k}" aria-selected="${k === tab}">${t(label)}</button>`).join("")}</div>
      <div id="tab-body"></div>
    </div>`;

  const actions = $("#actions");
  if (canRegister && full && !joined) {
    actions.innerHTML = `<span class="pill"><i class="dot"></i>${t("t.full")}</span>`;
  } else if (canRegister) {
    if (!user) actions.innerHTML = `<a class="btn" href="/auth.html?next=${encodeURIComponent(location.pathname)}">${t("t.signin")}</a>`;
    else if (joined) actions.innerHTML = `<span class="pill open"><i class="dot"></i>${t("t.registered")}</span><button class="btn ghost sm" id="wd">${t("t.withdraw")}</button>`;
    else actions.innerHTML = `<button class="btn" id="reg">${t("t.register")}</button>`;
  }
  actions.insertAdjacentHTML("beforeend", `<button class="btn ghost" id="share">${t("t.share")}</button>`);

  $("#reg")?.addEventListener("click", async (e) => {
    e.target.disabled = true;
    try {
      let r = await register(tour.id);
      if (!r.ok && r.reason === "country_required") {
        const saved = await chooseCountryAndSave();      // times are shown in the player's own time zone
        if (!saved) { e.target.disabled = false; return; }
        r = await register(tour.id);
      }
      if (r.ok) { joined = true; toast(t("t.registered")); await refresh(); }
      else { toast(t("r." + r.reason) === "r." + r.reason ? r.reason : t("r." + r.reason), "err"); e.target.disabled = false; }
    } catch (err) { toast(errMsg(err), "err"); e.target.disabled = false; }
  });
  $("#wd")?.addEventListener("click", async () => { try { await withdraw(tour.id); joined = false; await refresh(); } catch (err) { toast(errMsg(err), "err"); } });
  $("#share").addEventListener("click", async () => {
    const url = location.href;
    try { if (navigator.share) { await navigator.share({ title: tour.name, url }); return; } } catch (_) { return; }
    try { await navigator.clipboard.writeText(url); toast(t("t.copied")); } catch (_) { toast(url); }
  });
  $$("[data-tab]").forEach((b) => b.addEventListener("click", () => { tab = b.dataset.tab; render(); }));
  renderBody();
}

function renderBody() {
  const body = $("#tab-body");
  if (tour.status === "planning" && tab !== "players") {
    body.innerHTML = `<div class="empty" style="margin:36px 0">${esc(t("t.planning"))}</div>`;
    applyI18n(body);
    return;
  }
  const adv = tour.format === "league_knockout" ? tour.league_advance : 0;
  const zones = tour.format === "league_phase" ? phaseZones(data.entries.length) : null;
  if (tab === "stats") { renderStats(body); return; }
  body.innerHTML = tab === "bracket" ? renderBracket(data.fixtures, data.profiles)
    : tab === "groups" ? renderGroups(data.table, data.profiles)
    : tab === "table" ? renderTable(data.table, data.profiles, adv, zones)
    : tab === "fixtures" ? renderFixtures(data.fixtures, data.profiles)
    : renderPlayers(data.entries, data.profiles);
  applyI18n(body);
}

async function renderStats(body) {
  body.innerHTML = `<div class="empty" style="margin:28px 0">${esc(t("c.loading"))}</div>`;
  try {
    const [race, goals, assists, potm] = await Promise.all([playerStats(tour.id), leaders(tour.id, "goal"), leaders(tour.id, "assist"), leaders(tour.id, "potm")]);
    body.innerHTML = `<h3 class="stats-h">${esc(t("s.race"))}</h3>${renderRace(race, data.profiles, tour.format)}
      <div class="leaders-grid">
        ${renderLeaders(t("s.scorers"), goals, (r) => r.pens ? `${r.total} (${r.pens} ${t("s.pen")})` : r.total)}
        ${renderLeaders(t("s.assists"), assists, (r) => r.total)}
        ${renderLeaders(t("s.potm"), potm, (r) => r.avg_rating ? `${r.total} · ${r.avg_rating}` : r.total)}
      </div>`;
  } catch (e) { body.innerHTML = `<div class="empty">${esc(errMsg(e))}</div>`; }
  applyI18n(body);
}

boot();
