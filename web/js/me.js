import { mountChrome, esc, $, fmtDate, statusPill, errMsg, t, applyI18n, chooseCountryAndSave, toast } from "./ui.js";
import { getUser, myEntries, myFixtures, getProfiles, myProfile, LIVE, myNotifications, myFollows, markAllRead, setFollow, savePush, deletePush } from "./api.js";
import { CONFIG } from "./config.js";

await mountChrome();
const user = await getUser().catch(() => null);
if (!user) { location.replace(LIVE ? "/auth.html?next=/me.html" : "/auth.html"); }
else {
  async function showTz() {
    const p = await myProfile().catch(() => ({}));
    const line = $("#tz-line");
    line.innerHTML = p.country_name
      ? `${esc(t("c.times"))} <b>${esc(p.country_name)}</b> (${esc(p.tz)}). <a href="#" id="chg-country">${esc(t("me.change"))}</a>`
      : `${esc(t("a.countryhint"))} <a href="#" id="chg-country">${esc(t("a.choosecountry"))}</a>`;
    $("#chg-country").addEventListener("click", async (e) => { e.preventDefault(); try { if (await chooseCountryAndSave()) location.reload(); } catch (err) { errMsg(err); } });
  }
  showTz();
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

// ---------------------------------------------------------------- notifications

function keyBytes(b64url) {
  const pad = "=".repeat((4 - (b64url.length % 4)) % 4);
  const raw = atob((b64url + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

async function currentSub() {
  if (!pushSupported()) return null;
  const reg = await navigator.serviceWorker.ready;
  return reg.pushManager.getSubscription();
}

async function renderPushControl() {
  const host = $("#push-ctl");
  if (!host) return;
  if (!pushSupported() || !CONFIG.VAPID_PUBLIC_KEY) { host.innerHTML = `<span class="mute small">${esc(t("n.unsupported"))}</span>`; return; }
  if (Notification.permission === "denied") { host.innerHTML = `<span class="mute small">${esc(t("n.blocked"))}</span>`; return; }
  const sub = await currentSub().catch(() => null);
  if (sub && Notification.permission === "granted") {
    host.innerHTML = `<span class="pill open"><i class="dot"></i>${esc(t("n.active"))}</span><button class="btn sm ghost" id="push-off">${esc(t("n.off"))}</button>`;
    $("#push-off").onclick = async () => {
      try { const s = await currentSub(); if (s) { await deletePush(s.endpoint); await s.unsubscribe(); } } catch (err) { toast(errMsg(err), "err"); }
      renderPushControl();
    };
  } else {
    host.innerHTML = `<button class="btn sm" id="push-on">${esc(t("n.on"))}</button>`;
    $("#push-on").onclick = async (e) => {
      e.currentTarget.disabled = true;
      try {
        const perm = await Notification.requestPermission();
        if (perm !== "granted") { renderPushControl(); return; }
        const reg = await navigator.serviceWorker.ready;
        const s = (await reg.pushManager.getSubscription()) || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(CONFIG.VAPID_PUBLIC_KEY) });
        const j = s.toJSON();
        const r = await savePush(j.endpoint, j.keys.p256dh, j.keys.auth, navigator.userAgent);
        if (!r.ok) throw new Error(r.reason);
      } catch (err) { toast(errMsg(err), "err"); }
      renderPushControl();
    };
  }
}

async function renderNotifications() {
  const host = $("#notif-list");
  if (!host) return;
  const [list, follows] = await Promise.all([myNotifications(), myFollows()]);
  const asked = new Set(follows.filter((f) => f.state === "asked").map((f) => f.tournament_id));
  host.innerHTML = list.length ? list.map((n) => {
    const choose = (n.kind === "knocked_out" || n.kind === "not_qualified") && asked.has(n.tournament_id);
    return `<div class="notif ${n.read_at ? "" : "unread"}">
      <div><b>${esc(n.title)}</b><p>${esc(n.body)}</p><small>${esc(fmtDate(n.created_at))}</small>
        ${choose ? `<div class="a-actions" style="margin-top:10px"><button class="btn sm" data-follow="${esc(n.tournament_id)}" data-v="1">${esc(t("n.keep"))}</button><button class="btn sm ghost" data-follow="${esc(n.tournament_id)}" data-v="0">${esc(t("n.stop"))}</button></div>` : ""}</div>
      ${n.url ? `<a class="arrow" href="${esc(n.url)}" aria-label="Open">→</a>` : ""}</div>`;
  }).join("") : `<div class="empty">${esc(t("n.none"))}</div>`;
  host.querySelectorAll("[data-follow]").forEach((b) => b.addEventListener("click", () => chooseFollow(b.dataset.follow, b.dataset.v === "1")));
  if (list.some((n) => !n.read_at)) {
    markAllRead().then(() => { const badge = $("#unread"); if (badge) badge.hidden = true; }).catch(() => {});
  }
}

async function chooseFollow(tid, follow) {
  try {
    const r = await setFollow(tid, follow);
    if (!r.ok) throw new Error(r.reason);
    toast(t(follow ? "n.kept" : "n.stopped"));
    renderNotifications();
  } catch (err) { toast(errMsg(err), "err"); }
}

if (user) {
  // choice made from the phone notification buttons: /me.html?t=<tournament>&follow=1|0
  const q = new URLSearchParams(location.search);
  if (q.get("t") && (q.get("follow") === "1" || q.get("follow") === "0")) {
    chooseFollow(q.get("t"), q.get("follow") === "1");
    history.replaceState(null, "", "/me.html#notifications");
  }
  renderPushControl();
  renderNotifications().catch((e) => { $("#notif-list").innerHTML = `<div class="empty">${esc(errMsg(e))}</div>`; });
}
