import { mountChrome, esc, $ } from "./ui.js";
import { CONFIG } from "./config.js";
await mountChrome();
if (CONFIG.CONTACT_EMAIL) $("#contact-body").innerHTML = `Write to us at <a href="mailto:${esc(CONFIG.CONTACT_EMAIL)}">${esc(CONFIG.CONTACT_EMAIL)}</a>.`;
