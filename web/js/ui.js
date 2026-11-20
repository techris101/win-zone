import { t, applyI18n, setLang, getLang, LANGS } from "./i18n.js";
import { LIVE, getUser, signOut, isOrganizer } from "./api.js";
import { CONFIG } from "./config.js";

export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

export function fmtDate(ts) {
  if (!ts) return "—";
  return new Date(ts).toLocaleString(getLang(), { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}
export function nameOf(profiles, id) {
  if (!id) return null;
  const p = profiles[id];
  return p ? p.display_name || p.username : "…";
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

const NAV = [["/#tournaments", "nav.tournaments"], ["/#how", "nav.how"], ["/organizers.html", "nav.organizers"]];

export async function mountChrome(active = "") {
  document.documentElement.lang = getLang();
  const header = document.createElement("header");
  header.className = "site-header";
  header.innerHTML = `
    ${LIVE ? "" : `<div class="sample-banner" data-i18n="c.sample"></div>`}
    <div class="wrap nav">
      <a class="logo" href="/" aria-label="WIN ZONE"><span class="logo-mark"></span><span class="logo-text">WIN <b>ZONE</b></span></a>
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
        <div><a class="logo" href="/"><span class="logo-mark"></span><span class="logo-text">WIN <b>ZONE</b></span></a>
          <p class="mute" style="margin-top:16px;max-width:26em" data-i18n="f.tag"></p></div>
        <div><h4 data-i18n="f.product"></h4>
          <a href="/#tournaments" data-i18n="nav.tournaments"></a><a href="/#how" data-i18n="nav.how"></a><a href="/organizers.html" data-i18n="nav.organizers"></a></div>
        <div><h4 data-i18n="f.legal"></h4>
          <a href="/terms.html" data-i18n="f.terms"></a><a href="/privacy.html" data-i18n="f.privacy"></a><a href="/contact.html" data-i18n="f.contact"></a></div>
        <div><h4>Free to play</h4><p class="mute small">Free to enter. Skill-based. Play responsibly.</p></div>
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
    if (lb) { setLang(lb.dataset.lang); location.reload(); }
    if (e.target.closest(".menu-btn")) {
      const open = $("#nav-links").classList.toggle("open");
      e.target.closest(".menu-btn").setAttribute("aria-expanded", String(open));
    }
  });
  applyI18n(document);
  syncThemeBtn();
  renderAuthSlot();
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
    slot.innerHTML = `<a class="btn sm" href="/auth.html" data-i18n="nav.signin"></a>`;
  } else {
    const org = await isOrganizer();
    slot.innerHTML = `${org ? `<a class="btn sm ghost" href="/admin.html" data-i18n="nav.admin"></a> ` : ""}<a class="btn sm" href="/me.html" data-i18n="nav.me"></a>`;
    const nav = $("#nav-links");
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
  return `<span class="pill ${cls}"><i class="dot"></i>${esc(t((status === "active" ? "fx." : "st.") + status))}</span>`;
};
export { t, applyI18n, CONFIG };
