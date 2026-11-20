import { mountChrome, esc, statusPill, t, applyI18n } from "./ui.js";
import { listTournaments } from "./api.js";

await mountChrome();
const host = document.getElementById("t-list");

function row(x) {
  const players = x.entries?.[0]?.count ?? 0;
  return `<a class="t-row" href="/t/${encodeURIComponent(x.slug)}">
    <span class="name">${esc(x.name)}</span>
    <span class="meta">${esc(t("fm." + x.format))} · ${esc(x.game?.name || "")}</span>
    <span class="meta"><span class="num">${players}/${x.size}</span> ${esc(t("t.players").toLowerCase())}</span>
    <span>${statusPill(x.status)}</span><span class="arrow" aria-hidden="true">→</span></a>`;
}

try {
  const list = await listTournaments();
  host.innerHTML = list.length ? list.map(row).join("") : `<div class="empty">${esc(t("live.empty"))}</div>`;
} catch (e) {
  host.innerHTML = `<div class="empty">${esc(t("c.error"))}</div>`;
}
applyI18n(host);
