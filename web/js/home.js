import { mountChrome, esc, statusPill, t, applyI18n, errMsg } from "./ui.js";
import { listTournaments, homeSponsors } from "./api.js";

await mountChrome();
const host = document.getElementById("t-list");

function row(x) {
  const players = x.entries?.[0]?.count ?? 0;
  return `<a class="t-row" href="/t/${encodeURIComponent(x.slug)}">
    <span class="name">${esc(x.name)}${x.is_demo ? ` <span class="pill demo">${esc(t("t.demo"))}</span>` : ""}</span>
    <span class="meta">${esc(t("fm." + x.format))} · ${esc(x.game?.name || "")}</span>
    <span class="meta"><span class="num">${players}/${x.size}</span> ${esc(t("t.players").toLowerCase())}</span>
    <span>${statusPill(x.status)}</span><span class="arrow" aria-hidden="true">→</span></a>`;
}

try {
  const list = await listTournaments();
  host.innerHTML = list.length ? list.map(row).join("") : `<div class="empty">${esc(t("live.empty"))}</div>`;
} catch (e) {
  host.innerHTML = `<div class="empty">${esc(errMsg(e))}</div>`;
}
applyI18n(host);

// partners chosen by the admin ("show on home")
homeSponsors().then((list) => {
  if (!list.length) return;
  document.getElementById("sp-row").innerHTML = list.map((s) => {
    const inner = s.logo_url ? `<img src="${esc(s.logo_url)}" alt="${esc(s.name)}" loading="lazy">` : `<span>${esc(s.name)}</span>`;
    return s.website ? `<a class="sp-logo" href="${esc(s.website)}" target="_blank" rel="noopener sponsored">${inner}</a>` : `<span class="sp-logo">${inner}</span>`;
  }).join("");
  document.getElementById("partners").hidden = false;
  applyI18n(document.getElementById("partners"));
}).catch(() => {});
