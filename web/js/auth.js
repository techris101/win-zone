import { mountChrome, $, errMsg, t } from "./ui.js";
import { signIn, signUp, getUser, listCountries, sendPasswordReset, LIVE } from "./api.js";

await mountChrome();
const next = (() => {
  const n = new URLSearchParams(location.search).get("next") || "/me.html";
  return n.startsWith("/") && !n.startsWith("//") ? n : "/me.html";   // same-site paths only
})();

if (await getUser().catch(() => null)) location.replace(next);

const show = (which) => {
  $("#form-in").hidden = which !== "in"; $("#form-up").hidden = which !== "up"; $("#form-forgot").hidden = which !== "forgot";
  $("#tab-in").setAttribute("aria-selected", which === "in"); $("#tab-up").setAttribute("aria-selected", which === "up");
};
$("#tab-in").onclick = () => show("in");
$("#tab-up").onclick = () => show("up");
if (location.hash === "#register") show("up");
if (location.hash === "#forgot") show("forgot");
$("#go-forgot").onclick = (e) => { e.preventDefault(); $("#fg-email").value = $("#in-email").value.trim(); show("forgot"); };
$("#back-in").onclick = (e) => { e.preventDefault(); show("in"); };

// Country list for the sign-up form; preselect from the browser's language region or time zone.
listCountries().then((list) => {
  const sel = $("#up-country");
  sel.append(...list.map((c) => { const o = document.createElement("option"); o.value = c.code; o.textContent = c.name; return o; }));
  const region = ((navigator.language || "").split("-")[1] || "").toUpperCase();
  let guess = list.find((c) => c.code === region);
  if (!guess) { try { const tz = Intl.DateTimeFormat().resolvedOptions().timeZone; guess = list.find((c) => c.tz === tz); } catch (_) {} }
  if (guess) sel.value = guess.code;
}).catch(() => {});

const say = (el, text, kind) => { el.innerHTML = text ? `<div class="msg ${kind}"></div>` : ""; if (text) el.firstChild.textContent = text; };

$("#form-in").addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#in-msg"); say(msg, "");
  const email = $("#in-email").value.trim(), password = $("#in-pass").value;
  if (!email || !password) return say(msg, "Enter your email and password.", "err");
  try { await signIn({ email, password }); location.href = next; }
  catch (err) { say(msg, errMsg(err), "err"); }
});

$("#form-up").addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#up-msg"); say(msg, "");
  const username = $("#up-user").value.trim(), email = $("#up-email").value.trim(), password = $("#up-pass").value, country = $("#up-country").value;
  if (!/^[A-Za-z0-9_]{3,20}$/.test(username)) return say(msg, "Username: 3–20 letters, numbers or _.", "err");
  if (password.length < 8) return say(msg, "Password needs 8 or more characters.", "err");
  if (!country) return say(msg, "Please choose your country. It is used to show match times in your local time.", "err");
  if (!$("#up-agree").checked) return say(msg, "Please accept the terms.", "err");
  try {
    const r = await signUp({ email, password, username, country });
    if (r.session) location.href = next;
    else say(msg, "Account created. Check your email to confirm, then sign in.", "ok");
  } catch (err) { say(msg, errMsg(err), "err"); }
});
$("#form-forgot").addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#fg-msg"); say(msg, "");
  const email = $("#fg-email").value.trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return say(msg, "Enter the email of your account.", "err");
  const btn = e.submitter; if (btn) btn.disabled = true;
  try {
    await sendPasswordReset(email);
    // same answer whether or not the account exists, so nobody can test which emails are registered
    say(msg, "If an account uses this email, a reset link is on its way. Check your inbox and spam folder.", "ok");
  } catch (err) { say(msg, errMsg(err), "err"); }
  finally { if (btn) setTimeout(() => { btn.disabled = false; }, 30000); }
});

if (!LIVE) say($("#in-msg"), "Sample mode: accounts are enabled once the live service is connected.", "ok");
void t;
