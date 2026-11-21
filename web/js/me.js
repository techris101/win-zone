import { mountChrome, esc, $, fmtDate, statusPill, errMsg, t, applyI18n, chooseCountryAndSave, toast } from "./ui.js";
import { getUser, myEntries, myFixtures, getProfiles, myProfile, LIVE, careerStats, setMyTeamName, playerStats, myNotifications, myFollows, markAllRead, setFollow, savePush, deletePush,
         changePassword, takeBreak, setPlayLimit, deleteMyAccount, signOut } from "./api.js";
import { CONFIG } from "./config.js";
import { statusText } from "./bracket.js";

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
  $("#app-link").innerHTML = CONFIG.APK_URL ? `<a class="btn sm" href="${esc(CONFIG.APK_URL)}" rel="noopener">${esc(t("me.getapp"))}</a>` : "";
  try {
    const [fx, en] = await Promise.all([myFixtures(user.id), myEntries(user.id)]);
    const profiles = await getProfiles(fx.flatMap((f) => [f.player_a_id, f.player_b_id]));
    $("#me-fx").innerHTML = fx.length ? fx.map((f) => {
      const opp = f.player_a_id === user.id ? f.player_b_id : f.player_a_id;
      const o = profiles[opp];
      return `<div class="fx-item"><a class="t-row" href="/matchroom.html?f=${encodeURIComponent(f.id)}">
        <span class="name">vs ${esc(o ? o.display_name || o.username : "…")}</span>
        <span class="meta">${esc(f.tournament?.name || "")}</span>
        <span class="meta">${esc(fmtDate(f.scheduled_at))}</span>
        <span>${statusPill(f.status === "active" ? "active" : "scheduled")}</span><span class="arrow">→</span></a>
        ${f.scheduled_at ? `<button class="link-btn fx-cal" type="button" data-ics="${esc(f.id)}">${esc(t("cal.add"))}</button>` : ""}</div>`;
    }).join("") : `<div class="empty">${esc(t("me.none"))}</div>`;
    $("#me-ent").innerHTML = en.length ? en.map((e) => `<a class="t-row" href="/t/${encodeURIComponent(e.tournament.slug)}">
        <span class="name">${esc(e.tournament.name)}</span><span class="meta">${esc(fmtDate(e.tournament.starts_at))}</span>
        <span class="meta"></span><span>${statusPill(e.tournament.status)}</span><span class="arrow">→</span></a>`).join("") : `<div class="empty">${esc(t("me.none"))}</div>`;
    $("#me-fx").querySelectorAll("[data-ics]").forEach((b) => b.addEventListener("click", (e) => {
      const f = fx.find((x) => x.id === b.dataset.ics);
      const opp = profiles[f.player_a_id === user.id ? f.player_b_id : f.player_a_id];
      downloadIcs(f, opp ? opp.display_name || opp.username : "Opponent");
    }));
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

// ---------------------------------------------------------------- my stats
async function renderMyStats() {
  const c = await careerStats(user.id);
  if (c) {
    const rate = c.played ? Math.round((100 * c.won) / c.played) + "%" : "—";
    $("#career").innerHTML = `<div class="career">
      <div><b>${c.played}</b><span>${esc(t("me.played"))}</span></div><div><b>${c.won}</b><span>${esc(t("me.won"))}</span></div>
      <div><b>${rate}</b><span>${esc(t("me.winrate"))}</span></div><div><b>${c.goals_for}</b><span>${esc(t("me.goals"))}</span></div>
      <div><b>${c.titles}</b><span>${esc(t("me.titles"))}</span></div></div>`;
  }
  const entries = (await myEntries(user.id)).filter((e) => ["live", "completed"].includes(e.tournament.status));
  const lines = [];
  for (const e of entries.slice(0, 6)) {
    const rows = await playerStats(e.tournament.id).catch(() => []);
    const me = rows.find((r) => r.user_id === user.id);
    if (!me) continue;
    const where = me.pos ? ` · #${me.pos}, ${me.points} pts` : "";
    lines.push(`<div class="my-status"><a href="/t/${encodeURIComponent(e.tournament.slug)}"><b>${esc(e.tournament.name)}</b></a>
      <span>${esc(statusText(me, e.tournament.format || ""))}${esc(where)}</span></div>`);
  }
  $("#my-race").innerHTML = lines.join("");
}
if (user) renderMyStats().catch(() => {});

// ---------------------------------------------------------------- my team name (the app uses it to find my side of the screen)
if (user) {
  myProfile().then((p) => { if (p && p.team_name) $("#team-name").value = p.team_name; }).catch(() => {});
  $("#team-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      const r = await setMyTeamName($("#team-name").value);
      if (!r.ok) throw new Error(r.reason === "bad_name" ? "Use 2 to 30 characters." : r.reason);
      $("#team-name").value = r.team_name; toast(t("me.teamsaved"));
    } catch (err) { toast(errMsg(err), "err"); }
  });
}

// ---------------------------------------------------------------- calendar file for one match (opens in any calendar app)
function downloadIcs(f, oppName) {
  const stamp = (d) => new Date(d).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const start = new Date(f.scheduled_at), end = new Date(start.getTime() + 30 * 60000);
  const clean = (x) => String(x || "").replace(/[\\,;]/g, (m) => "\\" + m).replace(/\n/g, " ");
  const url = `${location.origin}/matchroom.html?f=${f.id}`;
  const ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//WIN ZONE//Match//EN", "CALSCALE:GREGORIAN", "BEGIN:VEVENT",
    `UID:${f.id}@win-zone`, `DTSTAMP:${stamp(Date.now())}`, `DTSTART:${stamp(start)}`, `DTEND:${stamp(end)}`,
    `SUMMARY:${clean(`WIN ZONE: vs ${oppName}`)}`, `DESCRIPTION:${clean(`${f.tournament?.name || ""} - open the match room: ${url}`)}`, `URL:${url}`,
    "BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY", "DESCRIPTION:WIN ZONE match in 15 minutes", "END:VALARM",
    "END:VEVENT", "END:VCALENDAR"].join("\r\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([ics], { type: "text/calendar" }));
  a.download = "win-zone-match.ics"; document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}

// ---------------------------------------------------------------- account and safety
const say = (el, text, kind = "err") => { el.innerHTML = text ? `<div class="msg ${kind}"></div>` : ""; if (text) el.firstChild.textContent = text; };
const reasonText = (r) => t("r." + r) === "r." + r ? r : t("r." + r);
const longDate = (d) => new Date(d).toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" });

async function renderAccount() {
  const p = await myProfile().catch(() => ({}));
  const banner = $("#acct-banner");
  const notes = [];
  if (p.banned_until) {
    const perm = new Date(p.banned_until).getFullYear() > 9000 || !isFinite(new Date(p.banned_until));
    notes.push(`<div class="msg err">${esc(perm ? t("ban.perm") : `${t("ban.until")} ${longDate(p.banned_until)}.`)} ${esc(t("ban.contact"))}</div>`);
  }
  if (p.break_until) notes.push(`<div class="msg ok">${esc(t("rp.onbreak"))} ${esc(longDate(p.break_until))}.</div>`);
  banner.innerHTML = notes.join("");
  $("#rp-limit").value = p.max_active_tournaments ? String(p.max_active_tournaments) : "";
}

if (user) {
  renderAccount();
  $("#pw-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = $("#pw-msg"); say(msg, "");
    const cur = $("#pw-cur").value, a = $("#pw-new").value, b = $("#pw-rep").value;
    if (a.length < 8) return say(msg, t("acc.pwshort"));
    if (a !== b) return say(msg, t("acc.pwsame"));
    try { await changePassword(user.email, cur, a); e.target.reset(); say(msg, t("acc.pwdone"), "ok"); }
    catch (err) { say(msg, err.message === "wrong_current_password" ? t("acc.pwwrong") : errMsg(err)); }
  });
  $("#rp-limit").addEventListener("change", async (e) => {
    try { const r = await setPlayLimit(e.target.value ? Number(e.target.value) : null); if (!r.ok) throw new Error(r.reason); toast(t("rp.limitsaved")); }
    catch (err) { toast(errMsg(err), "err"); }
  });
  $("#rp-break").addEventListener("click", async () => {
    if (!confirm(t("rp.confirm"))) return;
    try { const r = await takeBreak(Number($("#rp-days").value)); if (!r.ok) throw new Error(r.reason); await renderAccount(); }
    catch (err) { toast(errMsg(err), "err"); }
  });
  $("#del-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = $("#del-msg"); say(msg, "");
    try {
      const r = await deleteMyAccount($("#del-user").value);
      if (!r.ok) return say(msg, reasonText(r.reason));
      await signOut().catch(() => {});
      alert(t("del.done"));
      location.href = "/";
    } catch (err) { say(msg, errMsg(err)); }
  });
}
