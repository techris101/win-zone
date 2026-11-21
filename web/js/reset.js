import { mountChrome, $, errMsg } from "./ui.js";
import { sb, setNewPassword, LIVE } from "./api.js";

// Opened from the reset email. Supabase reads the link and signs the user in for this purpose only.
await mountChrome();
const say = (el, text, kind) => { el.innerHTML = text ? `<div class="msg ${kind}"></div>` : ""; if (text) el.firstChild.textContent = text; };
const wait = $("#np-wait"), form = $("#form-new");

const hash = new URLSearchParams(location.hash.slice(1));
const linkError = hash.get("error_description") || new URLSearchParams(location.search).get("error_description");

async function ready() {
  if (!LIVE) return say(wait, "Not connected to the live service.", "err");
  if (linkError) return expired();
  const c = await sb();
  let shown = false;
  const open = () => { if (shown) return; shown = true; wait.innerHTML = ""; form.hidden = false; $("#np-1").focus(); };
  c.auth.onAuthStateChange((event, session) => { if (event === "PASSWORD_RECOVERY" || session) open(); });
  const { data } = await c.auth.getSession();
  if (data.session) open();
  else { say(wait, "Checking your link…", "ok"); setTimeout(() => { if (!shown) expired(); }, 6000); }
}

function expired() {
  wait.innerHTML = '<div class="msg err">This reset link has expired or was already used. <a href="/auth.html#forgot">Ask for a new link</a>.</div>';
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("#np-msg"); say(msg, "");
  const a = $("#np-1").value, b = $("#np-2").value;
  if (a.length < 8) return say(msg, "Password needs 8 or more characters.", "err");
  if (a !== b) return say(msg, "The two passwords are not the same.", "err");
  try {
    await setNewPassword(a);
    form.hidden = true;
    wait.innerHTML = '<div class="msg ok">Your password is changed. <a href="/me.html">Go to My matches</a>.</div>';
  } catch (err) { say(msg, errMsg(err), "err"); }
});

ready();
