// Tests for the tournament description reader. Run: node web/js/describe.test.mjs
import { parseBrief } from "./describe.js";

const now = new Date(2026, 10, 20, 10, 0);   // Fri 20 Nov 2026, 10:00 local
let failed = 0;
const ok = (cond, msg) => { if (!cond) { failed++; console.log("FAIL:", msg); } else console.log("ok  :", msg); };
const at = (d) => (d ? `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()} ${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}` : null);

let r = parseBrief('"Kigali Cup" knockout for 16 players on 5 December at 18:00, fast. Prize: headphones', now);
ok(r.draft.name === "Kigali Cup" && r.draft.slug === "kigali-cup", "EN: name and link");
ok(r.draft.size === 16 && r.draft.format === "knockout", "EN: 16 players, knockout");
ok(at(r.draft.starts_at) === "2026-12-5 18:00", "EN: 5 December 18:00 (got " + at(r.draft.starts_at) + ")");
ok(r.draft.speed === "fast" && r.draft.prize === "headphones", "EN: fast, prize");

r = parseBrief('Tournoi "Coupe des Mille Collines" en poules pour 24 joueurs, samedi à 20h. Récompense : un maillot', now);
ok(r.draft.name === "Coupe des Mille Collines" && r.draft.format === "groups_knockout" && r.draft.size === 24, "FR: groups, 24 players");
ok(at(r.draft.starts_at) === "2026-11-21 20:00", "FR: next Saturday 20:00 (got " + at(r.draft.starts_at) + ")");
ok(r.draft.prize === "un maillot", "FR: prize");

r = parseBrief('Irushanwa "Igikombe cya Huye": shampiyona n\'imikino yo gusezerera, abakinnyi 10, ejo saa 18:00, buri munsi', now);
ok(r.draft.name === "Igikombe cya Huye" && r.draft.format === "league_knockout" && r.draft.size === 10, "RW: league + knockout, 10 players");
ok(at(r.draft.starts_at) === "2026-11-21 18:00" && r.draft.speed === "fast", "RW: tomorrow 18:00, daily");

r = parseBrief("Champions League style league for 40 players, 6 matches each, starting 2026-12-01 19:30", now);
ok(r.draft.format === "league_phase" && r.draft.size === 40 && r.draft.rounds === 6, "league phase, 40 players, 6 matches each");
ok(at(r.draft.starts_at) === "2026-12-1 19:30", "ISO date with time");

r = parseBrief("November Clash, 5 players", now);
ok(r.draft.name === "November Clash" && r.draft.format === "league" && !r.found.format, "no format given: recommended League for 5 players");

r = parseBrief('"Night Cup" 8 players at 21:00, one day event', now);
ok(at(r.draft.starts_at) === "2026-11-20 21:00" && r.draft.speed === "oneday", "time only: tonight 21:00, one-day");

r = parseBrief('"Early Cup" 4 players at 07:00', now);
ok(at(r.draft.starts_at) === "2026-11-21 7:00", "time already passed today: tomorrow");

r = parseBrief('"League K" league then knockout, top 8 go through, 20 players, 5/12', now);
ok(r.draft.format === "league_knockout" && r.draft.advance === 8 && at(r.draft.starts_at) === "2026-12-5 18:00", "top 8, day/month date, default 18:00");

r = parseBrief("", now);
ok(r.draft.name === "" && r.draft.size === 8 && !r.found.size, "empty text gives safe defaults");

console.log(failed ? `${failed} FAILED` : "ALL DESCRIBE TESTS PASSED");
process.exit(failed ? 1 : 0);
