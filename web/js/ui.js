import { t, applyI18n, setLang, getLang, LANGS } from "./i18n.js";
import { LIVE, getUser, signOut, isOrganizer, myProfile, listCountries, setMyCountry, unreadCount, onMyNotification, setMyLang } from "./api.js";
import { CONFIG } from "./config.js";

export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

// Times are stored in UTC and shown in the player's own time zone (from their country), else the browser's.
export function setTz(tz) {
  try { if (tz) localStorage.setItem("wz_tz", tz); else localStorage.removeItem("wz_tz"); } catch (_) {}
}
export function currentTz() {
  try { return localStorage.getItem("wz_tz") || undefined; } catch (_) { return undefined; }
}
export function fmtDate(ts, tz) {
  if (!ts) return "—";
  const opts = { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZoneName: "short" };
  try { return new Date(ts).toLocaleString(getLang(), { ...opts, timeZone: tz || currentTz() }); }
  catch (_) { return new Date(ts).toLocaleString(getLang(), opts); }
}

// Wall-clock helpers for the admin: type a time in the tournament's zone, store it as UTC.
function tzOffsetMs(ts, tz) {
  const o = {};
  new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
    .formatToParts(new Date(ts)).forEach((p) => { o[p.type] = p.value; });
  return Date.UTC(o.year, o.month - 1, o.day, o.hour, o.minute, o.second) - ts;
}
export function wallToUtc(str, tz) {   // "2026-12-05T18:00" in tz -> Date
  const [d, t] = str.split("T"); const [y, m, da] = d.split("-").map(Number); const [h, mi] = t.split(":").map(Number);
  const wall = Date.UTC(y, m - 1, da, h, mi); let guess = wall;
  for (let i = 0; i < 2; i++) guess = wall - tzOffsetMs(guess, tz);
  return new Date(guess);
}
export function utcToWall(ts, tz) {    // -> "2026-12-05T18:00" as seen in tz
  const o = {};
  new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })
    .formatToParts(new Date(ts)).forEach((p) => { o[p.type] = p.value; });
  return `${o.year}-${o.month}-${o.day}T${o.hour}:${o.minute}`;
}

// A small accessible dialog asking for the player's country. Resolves to a code, or null if cancelled.
export async function askCountry() {
  const list = (await listCountries()).filter((c) => !c.blocked);
  return new Promise((resolve) => {
    const d = document.createElement("dialog");
    d.className = "dlg";
    d.innerHTML = `<form method="dialog" class="form"><h3>${esc(t("a.country"))}</h3><p class="mute small">${esc(t("a.countryhint"))}</p>
      <div class="field"><select required aria-label="${esc(t("a.country"))}"><option value="">${esc(t("a.choosecountry"))}</option>
      ${list.map((c) => `<option value="${esc(c.code)}">${esc(c.name)}</option>`).join("")}</select></div>
      <div class="a-actions"><button class="btn" value="ok">${esc(t("c.save"))}</button><button class="btn ghost" value="cancel" formnovalidate>${esc(t("c.cancel"))}</button></div></form>`;
    document.body.append(d);
    d.addEventListener("close", () => { const v = d.returnValue === "ok" ? d.querySelector("select").value : null; d.remove(); resolve(v || null); });
    d.showModal();
  });
}
export async function chooseCountryAndSave() {
  const code = await askCountry();
  if (!code) return null;
  const r = await setMyCountry(code);
  if (!r.ok) throw new Error(r.reason || "could not save country");
  setTz(r.tz);
  return r;
}
export function nameOf(profiles, id) {
  if (!id) return null;
  const p = profiles[id];
  return p ? p.display_name || p.username : "…";
}
// a player's name linking to their public page
export function playerLink(profiles, id) {
  const p = id && profiles[id];
  if (!p) return esc(nameOf(profiles, id) || "");
  return `<a class="plink" href="/p/${encodeURIComponent(p.username)}">${esc(p.display_name || p.username)}</a>`;
}

export function toast(msg, kind = "") {
  let host = $(".toast-host");
  if (!host) { host = document.createElement("div"); host.className = "toast-host"; host.setAttribute("role", "status"); document.body.append(host); }
  const el = document.createElement("div");
  el.className = `toast ${kind}`; el.textContent = msg; host.append(el);
  setTimeout(() => el.remove(), 4200);
}
export function errMsg(e) {
  if (e && e.message === "not_connected") return "The live service is not connected yet.";
  if (e && e.message === "not_ready") return "The live service is being set up. Please check back soon.";
  return (e && e.message) || t("c.error");
}

const NAV = [["/#tournaments", "nav.tournaments"], ["/players.html", "nav.players"], ["/#how", "nav.how"], ["/organizers.html", "nav.organizers"]];

// The service worker shows notifications on the phone even when the site is closed.
if (typeof navigator !== "undefined" && "serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

// The brand: the WZ monogram (W and Z sharing one stroke) with the volt "winning point", and a plain wordmark.
export const LOGO_INNER = `<svg class="logo-mark" viewBox="-3 1.5 123 77.0" aria-hidden="true" focusable="false"><g class="lm-line" fill="none" stroke-width="13" stroke-miterlimit="10"><path d="M2.12,-4.41 L26,72 L46,32 L66,72"/><path d="M60,8 L104,8 L66,72 L114,72"/></g><path class="lm-dot" d="M84.80,61.30 L94.89,44.30 L104.30,61.30Z"/></svg><span class="logo-text">WIN ZONE</span>`;

export async function mountChrome(active = "") {
  document.documentElement.lang = getLang();
  const header = document.createElement("header");
  header.className = "site-header";
  header.innerHTML = `
    ${LIVE ? "" : `<div class="sample-banner" data-i18n="c.sample"></div>`}
    <div class="wrap nav">
      <a class="logo" href="/" aria-label="WIN ZONE home">${LOGO_INNER}</a>
      <nav class="nav-links" id="nav-links" aria-label="Main">
        ${NAV.map(([href, key]) => `<a href="${href}" data-i18n="${key}" ${active === key ? 'aria-current="page"' : ""}></a>`).join("")}
        <div class="lang lang-m" role="group" aria-label="Language">
          ${LANGS.map((l) => `<button type="button" data-lang="${l}" aria-pressed="${l === getLang()}">${l.toUpperCase()}</button>`).join("")}
        </div>
      </nav>
      <div class="nav-end">
        <div class="lang" role="group" aria-label="Language">
          ${LANGS.map((l) => `<button type="button" data-lang="${l}" aria-pressed="${l === getLang()}">${l.toUpperCase()}</button>`).join("")}
        </div>
        <button class="theme-btn" type="button" id="theme-btn">
          <svg class="i-moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
          <svg class="i-sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
        </button>
        <span id="auth-slot"></span>
        <button class="menu-btn" type="button" aria-expanded="false" aria-controls="nav-links" data-i18n="nav.menu"></button>
      </div>
    </div>`;
  document.body.prepend(header);

  const footer = document.createElement("footer");
  footer.className = "site-footer";
  footer.innerHTML = `
    <div class="wrap">
      <div class="foot-grid">
        <div><a class="logo" href="/" aria-label="WIN ZONE home">${LOGO_INNER}</a>
          <p class="mute" style="margin-top:16px;max-width:26em" data-i18n="f.tag"></p></div>
        <div><h4 data-i18n="f.product"></h4>
          <a href="/#tournaments" data-i18n="nav.tournaments"></a><a href="/#how" data-i18n="nav.how"></a><a href="/organizers.html" data-i18n="nav.organizers"></a></div>
        <div><h4 data-i18n="f.legal"></h4>
          <a href="/terms.html" data-i18n="f.terms"></a><a href="/privacy.html" data-i18n="f.privacy"></a><a href="/responsible.html" data-i18n="f.responsible"></a><a href="/contact.html" data-i18n="f.contact"></a></div>
        <div><h4>Free to play</h4><p class="mute small">Free to enter. Skill-based. Play responsibly.</p>
          ${CONFIG.APK_URL ? `<a href="${esc(CONFIG.APK_URL)}" rel="noopener" data-i18n="me.getapp"></a>` : ""}</div>
      </div>
      <div class="foot-base"><span>© ${new Date().getFullYear()} WIN ZONE. <span data-i18n="f.rights"></span></span><span>win-zone.pages.dev</span></div>
    </div>`;
  document.body.append(footer);

  header.addEventListener("click", (e) => {
    if (e.target.closest("#theme-btn")) {
      const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try { localStorage.setItem("wz_theme", next); } catch (_) {}
      syncThemeBtn();
    }
    const lb = e.target.closest("[data-lang]");
    if (lb) {
      setLang(lb.dataset.lang);
      // signed-in players also get notifications in this language
      getUser().then((u) => (u ? setMyLang(lb.dataset.lang) : null)).catch(() => {}).finally(() => location.reload());
    }
    if (e.target.closest(".menu-btn")) {
      const open = $("#nav-links").classList.toggle("open");
      e.target.closest(".menu-btn").setAttribute("aria-expanded", String(open));
    }
  });
  applyI18n(document);
  syncThemeBtn();
  await renderAuthSlot();
}

function syncThemeBtn() {
  const btn = $("#theme-btn");
  if (!btn) return;
  const dark = document.documentElement.dataset.theme === "dark";
  const label = t(dark ? "nav.light" : "nav.dark");
  btn.setAttribute("aria-label", label);
  btn.title = label;
  btn.setAttribute("aria-pressed", String(dark));
}

async function renderAuthSlot() {
  const slot = $("#auth-slot");
  if (!slot) return;
  let user = null;
  try { user = await getUser(); } catch (_) {}
  if (!user) {
    setTz(null);
    slot.innerHTML = `<a class="btn sm" href="/auth.html" data-i18n="nav.signin"></a>`;
  } else {
    try { const p = await myProfile(); setTz(p && p.tz ? p.tz : null); } catch (_) {}
    const org = await isOrganizer();
    slot.innerHTML = `${org ? `<a class="btn sm ghost nav-admin-d" href="/admin.html" data-i18n="nav.admin"></a> ` : ""}<a class="btn sm" href="/me.html" id="me-btn"><span data-i18n="nav.me"></span><span class="badge" id="unread" hidden></span></a>`;
    const setBadge = (n) => { const b = $("#unread"); if (!b) return; b.hidden = !n; b.textContent = n > 9 ? "9+" : String(n); };
    unreadCount().then(setBadge).catch(() => {});
    // live: a new notification bumps the badge and shows a short message
    onMyNotification(user.id, (n) => { unreadCount().then(setBadge); toast(n.title); }).catch(() => {});
    const nav = $("#nav-links");
    if (org) {   // on phones the Admin button lives in the menu
      const adm = document.createElement("a");
      adm.href = "/admin.html"; adm.dataset.i18n = "nav.admin"; adm.className = "nav-admin-m";
      nav.append(adm);
    }
    const out = document.createElement("a");
    out.href = "#"; out.dataset.i18n = "nav.signout";
    out.addEventListener("click", async (e) => { e.preventDefault(); await signOut(); location.href = "/"; });
    nav.append(out);
  }
  applyI18n(slot);
  applyI18n($("#nav-links"));
}

export const statusPill = (status) => {
  const cls = status === "live" || status === "active" ? "live" : status === "open" ? "open" : status === "completed" ? "done" : "";
  const key = ["active", "scheduled", "disputed", "stalled", "bye"].includes(status) ? "fx." + status : "st." + status;   // match states vs tournament states
  return `<span class="pill ${cls}"><i class="dot"></i>${esc(t(key))}</span>`;
};
export { t, applyI18n, CONFIG };
