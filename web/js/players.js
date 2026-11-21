import { mountChrome, esc, $, t, errMsg, applyI18n } from "./ui.js";
import { rankings } from "./api.js";

await mountChrome("nav.players");
const host = $("#rankings");

function render(rows) {
  if (!rows.length) { host.innerHTML = `<div class="empty">${esc(t("pl.none"))}</div>`; return; }
  host.innerHTML = `<div class="table-wrap"><table class="std rank-table"><thead><tr>
      <th>${t("tb.rank")}</th><th>${t("tb.player")}</th><th>${t("pl.titles")}</th><th>${t("pl.played")}</th><th>${t("tb.w")}</th><th>${t("tb.d")}</th><th>${t("tb.l")}</th><th>${t("tb.gd")}</th><th>${t("pl.winrate")}</th><th>${t("tb.pts")}</th></tr></thead><tbody>
    ${rows.map((r) => `<tr><td>${r.rank}</td>
      <td><a class="plink" href="/p/${encodeURIComponent(r.username)}">${esc(r.display_name || r.username)}</a>${r.team_name ? ` <span class="mute small">${esc(r.team_name)}</span>` : ""}</td>
      <td>${r.titles}</td><td>${r.played}</td><td>${r.won}</td><td>${r.drawn}</td><td>${r.lost}</td><td>${r.gf - r.ga > 0 ? "+" : ""}${r.gf - r.ga}</td>
      <td>${Number(r.win_rate).toFixed(0)}%</td><td class="pts">${r.points}</td></tr>`).join("")}
    </tbody></table></div>`;
}

let timer;
async function load(q) {
  try { render(await rankings(q)); } catch (e) { host.innerHTML = `<div class="empty">${esc(errMsg(e))}</div>`; }
}
$("#pl-search").addEventListener("input", (e) => { clearTimeout(timer); timer = setTimeout(() => load(e.target.value.trim()), 300); });
load(null);
applyI18n(document);
