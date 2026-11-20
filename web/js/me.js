import { mountChrome, esc, $, fmtDate, statusPill, errMsg, t, applyI18n } from "./ui.js";
import { getUser, myEntries, myFixtures, getProfiles, LIVE } from "./api.js";
import { CONFIG } from "./config.js";

await mountChrome();
const user = await getUser().catch(() => null);
if (!user) { location.replace(LIVE ? "/auth.html?next=/me.html" : "/auth.html"); }
else {
  $("#app-link").innerHTML = CONFIG.APK_URL ? `<a class="btn sm" href="${esc(CONFIG.APK_URL)}">${t("me.getapp")}</a>` : "";
  try {
    const [fx, en] = await Promise.all([myFixtures(user.id), myEntries(user.id)]);
    const profiles = await getProfiles(fx.flatMap((f) => [f.player_a_id, f.player_b_id]));
    $("#me-fx").innerHTML = fx.length ? fx.map((f) => {
      const opp = f.player_a_id === user.id ? f.player_b_id : f.player_a_id;
      const o = profiles[opp];
      return `<a class="t-row" href="/matchroom.html?f=${encodeURIComponent(f.id)}">
        <span class="name">vs ${esc(o ? o.display_name || o.username : "…")}</span>
        <span class="meta">${esc(f.tournament?.name || "")}</span>
        <span class="meta">${esc(fmtDate(f.scheduled_at))}</span>
        <span>${statusPill(f.status === "active" ? "active" : "scheduled")}</span><span class="arrow">→</span></a>`;
    }).join("") : `<div class="empty">${esc(t("me.none"))}</div>`;
    $("#me-ent").innerHTML = en.length ? en.map((e) => `<a class="t-row" href="/t/${encodeURIComponent(e.tournament.slug)}">
        <span class="name">${esc(e.tournament.name)}</span><span class="meta">${esc(fmtDate(e.tournament.starts_at))}</span>
        <span class="meta"></span><span>${statusPill(e.tournament.status)}</span><span class="arrow">→</span></a>`).join("") : `<div class="empty">${esc(t("me.none"))}</div>`;
  } catch (e) { $("#me-fx").innerHTML = `<div class="empty">${esc(errMsg(e))}</div>`; }
  applyI18n(document);
}
