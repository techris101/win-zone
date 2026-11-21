import { mountChrome, esc, $, t, errMsg, fmtDate, statusPill, toast } from "./ui.js";
import { publicPlayer, getUser, reportPlayer } from "./api.js";

await mountChrome("nav.players");
const root = $("#p-root");
const username = decodeURIComponent((location.pathname.match(/^\/p\/([^/]+)/) || [])[1] || new URLSearchParams(location.search).get("u") || "");

function notFound(msg) {
  root.innerHTML = `<div class="wrap prose"><span class="eyebrow">404</span><h1>${esc(t("p.notfound"))}</h1>${msg ? `<p class="lede">${esc(msg)}</p>` : ""}<a class="btn" href="/players.html">${esc(t("pl.title"))}</a></div>`;
}

async function load() {
  if (!username) return notFound();
  let p;
  try { p = await publicPlayer(username); } catch (e) { return notFound(errMsg(e)); }
  if (!p || !p.ok) return notFound(p && p.reason === "not_connected" ? errMsg({ message: "not_connected" }) : "");
  document.title = `${p.display_name || p.username} — WIN ZONE`;
  const c = p.career || {};
  const rate = c.played ? Math.round((100 * c.won) / c.played) + "%" : "—";
  root.innerHTML = `
    <section class="p-head"><div class="wrap">
      <span class="eyebrow">${p.rank ? `${esc(t("p.rank"))} #${p.rank}` : esc(t("pl.title"))}</span>
      <h1>${esc(p.display_name || p.username)}</h1>
      ${p.team_name ? `<div class="p-team">${esc(t("p.team"))}: ${esc(p.team_name)}</div>` : ""}
      <div class="career">
        <div><b>${c.titles ?? 0}</b><span>${esc(t("pl.titles"))}</span></div><div><b>${c.played ?? 0}</b><span>${esc(t("pl.played"))}</span></div>
        <div><b>${c.won ?? 0}</b><span>${esc(t("me.won"))}</span></div><div><b>${rate}</b><span>${esc(t("me.winrate"))}</span></div>
        <div><b>${c.goals_for ?? 0}</b><span>${esc(t("me.goals"))}</span></div></div>
      <p class="mute small">${esc(t("p.since"))} ${esc(new Date(p.since).toLocaleDateString())} · <button class="link-btn" type="button" id="rep-open">${esc(t("rep.link"))}</button></p>
      <form id="rep-form" class="panel form report-form" hidden>
        <h4 class="form-title">${esc(t("rep.title"))}</h4>
        <div class="field"><label for="r-reason">${esc(t("rep.reason"))}</label><select id="r-reason">
          ${["cheating", "abuse", "impersonation", "no_show", "other"].map((k) => `<option value="${k}">${esc(t("rep." + k))}</option>`).join("")}</select></div>
        <div class="field"><label for="r-details">${esc(t("rep.details"))}</label><textarea id="r-details" rows="3" maxlength="1000"></textarea></div>
        <button class="btn sm" type="submit">${esc(t("rep.send"))}</button>
      </form>
    </div></section>
    <div class="wrap p-cols">
      <section><h3>${esc(t("p.recent"))}</h3>${p.recent.length ? p.recent.map((r) => `<div class="res">
          <span class="r ${r.result}">${r.result}</span>
          <span>vs ${r.opponent_username ? `<a class="plink" href="/p/${encodeURIComponent(r.opponent_username)}">${esc(r.opponent)}</a>` : esc(r.opponent || "")}
            <small><a class="plink" href="/t/${encodeURIComponent(r.slug)}">${esc(r.tournament)}</a> · ${esc(fmtDate(r.at))}</small></span>
          <span class="sc">${r.me ?? ""}–${r.opp ?? ""}</span></div>`).join("") : `<div class="empty">—</div>`}</section>
      <section><h3>${esc(t("p.tournaments"))}</h3>${p.tournaments.length ? `<div class="t-list">${p.tournaments.map((x) => `<a class="t-row" href="/t/${encodeURIComponent(x.slug)}">
          <span class="name">${esc(x.name)}</span><span class="meta">${esc(t("fm." + x.format))}</span><span class="meta">${x.champion ? `<b>${esc(t("p.champion"))}</b>` : ""}</span>
          <span>${statusPill(x.status)}</span><span class="arrow">→</span></a>`).join("")}</div>` : `<div class="empty">—</div>`}</section>
    </div>`;
}
await load();

const me = await getUser().catch(() => null);
$("#rep-open")?.addEventListener("click", () => {
  if (!me) { location.href = `/auth.html?next=${encodeURIComponent(location.pathname)}`; return; }
  const f = $("#rep-form"); f.hidden = !f.hidden; if (!f.hidden) $("#r-reason").focus();
});
$("#rep-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  try {
    const r = await reportPlayer(username, $("#r-reason").value, $("#r-details").value);
    if (!r.ok) throw new Error(t("r." + r.reason) === "r." + r.reason ? r.reason : t("r." + r.reason));
    toast(t("rep.sent")); e.target.reset(); e.target.hidden = true;
  } catch (err) { toast(errMsg(err), "err"); }
});
