import { mountChrome, $, errMsg, t } from "./ui.js";
import { signIn, signUp, getUser, LIVE } from "./api.js";

await mountChrome();
const next = (() => {
  const n = new URLSearchParams(location.search).get("next") || "/me.html";
  return n.startsWith("/") && !n.startsWith("//") ? n : "/me.html";   // same-site paths only
})();

if (await getUser().catch(() => null)) location.replace(next);

const show = (which) => {
  $("#form-in").hidden = which !== "in"; $("#form-up").hidden = which !== "up";
  $("#tab-in").setAttribute("aria-selected", which === "in"); $("#tab-up").setAttribute("aria-selected", which === "up");
};
$("#tab-in").onclick = () => show("in");
$("#tab-up").onclick = () => show("up");
if (location.hash === "#register") show("up");

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
  const username = $("#up-user").value.trim(), email = $("#up-email").value.trim(), password = $("#up-pass").value;
  if (!/^[A-Za-z0-9_]{3,20}$/.test(username)) return say(msg, "Username: 3–20 letters, numbers or _.", "err");
  if (password.length < 8) return say(msg, "Password needs 8 or more characters.", "err");
  if (!$("#up-age").checked || !$("#up-agree").checked) return say(msg, "Please confirm your age and accept the terms.", "err");
  try {
    const r = await signUp({ email, password, username });
    if (r.session) location.href = next;
    else say(msg, "Account created. Check your email to confirm, then sign in.", "ok");
  } catch (err) { say(msg, errMsg(err), "err"); }
});
if (!LIVE) say($("#in-msg"), "Sample mode: accounts are enabled once the live service is connected.", "ok");
void t;
