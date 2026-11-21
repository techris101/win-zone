// Reads a plain description of a tournament (English, French or Kinyarwanda) and turns it into a draft.
// Rule-based and free: it looks for known words and patterns. Anything it does not find is left for the
// admin to fill in, and the format falls back to the research-based recommendation for the player count.

const MONTHS = {
  january: 0, jan: 0, janvier: 0, mutarama: 0,
  february: 1, feb: 1, fevrier: 1, février: 1, gashyantare: 1,
  march: 2, mar: 2, mars: 2, werurwe: 2,
  april: 3, apr: 3, avril: 3, mata: 3,
  may: 4, mai: 4, gicurasi: 4,
  june: 5, jun: 5, juin: 5, kamena: 5,
  july: 6, jul: 6, juillet: 6, nyakanga: 6,
  august: 7, aug: 7, aout: 7, août: 7, kanama: 7,
  september: 8, sep: 8, sept: 8, septembre: 8, nzeri: 8,
  october: 9, oct: 9, octobre: 9, ukwakira: 9,
  november: 10, nov: 10, novembre: 10, ugushyingo: 10,
  december: 11, dec: 11, decembre: 11, décembre: 11, ukuboza: 11,
};
const WEEKDAYS = {
  sunday: 0, dimanche: 0, "ku cyumweru": 0,
  monday: 1, lundi: 1, "kuwa mbere": 1,
  tuesday: 2, mardi: 2, "kuwa kabiri": 2,
  wednesday: 3, mercredi: 3, "kuwa gatatu": 3,
  thursday: 4, jeudi: 4, "kuwa kane": 4,
  friday: 5, vendredi: 5, "kuwa gatanu": 5,
  saturday: 6, samedi: 6, "kuwa gatandatu": 6,
};

export const FORMATS = ["league", "league_knockout", "groups_knockout", "league_phase", "knockout"];
export const recommendFormat = (n) => (n <= 6 ? "league" : n <= 11 ? "league_knockout" : n <= 31 ? "groups_knockout" : "league_phase");

const has = (text, words) => words.some((w) => text.includes(w));

function findName(raw) {
  const quoted = raw.match(/["“«]([^"”»]{3,60})["”»]/);
  if (quoted) return quoted[1].trim();
  const called = raw.match(/\b(?:called|named|name[:\s]|nommée?|appelée?|izina(?:\s+ryaryo)?(?:\s+ni)?)\s*:?\s*([A-Za-zÀ-ÿ0-9' .&-]{3,60}?)(?=[,.;\n]|\s+(?:with|for|avec|pour|na|ku|kuri|starting|start|on|le|du)\b|$)/i);
  if (called) return called[1].trim();
  const first = raw.split(/[\n.,:]/)[0].trim();
  if (first && first.length <= 40 && !/\d/.test(first) && first.split(/\s+/).length <= 5) return first;
  return null;
}

function findSize(t) {
  const m = t.match(/(\d{1,3})\s*(?:players?|teams?|participants?|gamers?|joueurs?|équipes?|equipes?|participants?)\b/)
    || t.match(/\b(?:abakinnyi|amakipe|abitabiriye)\s*(?:ba|bagera kuri|bangana na)?\s*(\d{1,3})\b/)
    || t.match(/\b(?:for|pour|of|de)\s+(\d{1,3})\b/);
  const n = m ? Number(m[1]) : null;
  return n && n >= 2 && n <= 128 ? n : null;
}

function findFormat(t) {
  if (has(t, ["champions league", "league phase", "swiss", "phase de ligue", "ligue des champions", "icyiciro cya shampiyona"])) return "league_phase";
  if (has(t, ["group", "world cup", "poule", "groupe", "coupe du monde", "amatsinda", "itsinda", "igikombe cy'isi"])) return "groups_knockout";
  const league = has(t, ["league", "round robin", "round-robin", "everyone plays everyone", "championnat", "shampiyona", "tout le monde joue"]);
  const ko = has(t, ["knockout", "knock-out", "play-off", "playoff", "elimination", "élimination", "gusezerera", "semi", "demi", "final"]);
  if (league && ko) return "league_knockout";
  if (league) return "league";
  if (has(t, ["knockout", "knock-out", "cup", "elimination", "élimination", "coupe", "gusezerera", "igikombe"])) return "knockout";
  return null;
}

function findAdvance(t) {
  const m = t.match(/\btop\s*(\d{1,2})\b/) || t.match(/\b(\d{1,2})\s*(?:qualify|advance|go through|se qualifient|passent|bakomeza)\b/)
    || t.match(/\bles\s+(\d{1,2})\s+premiers\b/) || t.match(/\b(\d{1,2})\s+ba\s+mbere\b/);
  const n = m ? Number(m[1]) : null;
  return [2, 4, 8, 16].includes(n) ? n : null;
}

function findRounds(t) {
  const m = t.match(/\b(\d{1,2})\s*(?:matches|games|rounds|matchs|matchs chacun|imikino)\s*(?:each|per player|chacun|par joueur|buri wese)?\b/)
    || t.match(/\b(?:imikino)\s*(\d{1,2})\b/);
  const n = m ? Number(m[1]) : null;
  return n && n >= 3 && n <= 12 ? n : null;
}

function findSpeed(t) {
  if (has(t, ["one day", "one-day", "same day", "today only", "in a day", "en une journée", "en un jour", "umunsi umwe", "every 45"])) return "oneday";
  if (has(t, ["fast", "daily", "every day", "each day", "every 24", "chaque jour", "tous les jours", "rapide", "buri munsi", "vuba"])) return "fast";
  if (has(t, ["every 48", "every two days", "every 2 days", "tous les deux jours", "tous les 2 jours", "buri minsi ibiri", "standard"])) return "standard";
  return null;
}

function findTime(t) {
  let m = t.match(/\b(\d{1,2})[:h](\d{2})\b/);              // 18:00, 18h30
  if (m) return [Number(m[1]), Number(m[2])];
  m = t.match(/\b(\d{1,2})\s*(am|pm)\b/);                    // 6pm
  if (m) { let h = Number(m[1]) % 12; if (m[2] === "pm") h += 12; return [h, 0]; }
  m = t.match(/\b(\d{1,2})h\b/);                             // 18h
  if (m) return [Number(m[1]), 0];
  m = t.match(/\b(?:at|à|saa)\s+(\d{1,2})\b/);               // at 20
  if (m) return [Number(m[1]), 0];
  return null;
}

function findDate(t, now) {
  const base = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let m = t.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
  if (m) return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  m = t.match(/\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\b/);
  if (m && Number(m[2]) <= 12) {
    let y = m[3] ? Number(m[3]) : base.getFullYear();
    if (y < 100) y += 2000;
    const d = new Date(y, Number(m[2]) - 1, Number(m[1]));
    if (!m[3] && d < base) d.setFullYear(d.getFullYear() + 1);
    return d;
  }
  const monthNames = Object.keys(MONTHS).sort((a, b) => b.length - a.length).join("|");
  m = t.match(new RegExp(`\\b(\\d{1,2})(?:st|nd|rd|th|er)?\\s+(?:of\\s+)?(${monthNames})\\b`)) ||
      t.match(new RegExp(`\\b(${monthNames})\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b`));
  if (m) {
    const day = Number(/\d/.test(m[1]) ? m[1] : m[2]);
    const month = MONTHS[/\d/.test(m[1]) ? m[2] : m[1]];
    const d = new Date(base.getFullYear(), month, day);
    if (d < base) d.setFullYear(d.getFullYear() + 1);
    return d;
  }
  if (has(t, ["day after tomorrow", "après-demain", "apres-demain", "ejobundi"])) return new Date(base.getTime() + 2 * 86400000);
  if (has(t, ["tomorrow", "demain", "ejo"])) return new Date(base.getTime() + 86400000);
  if (has(t, ["today", "tonight", "aujourd'hui", "ce soir", "uyu munsi", "iri joro"])) return base;
  for (const [name, wd] of Object.entries(WEEKDAYS).sort((a, b) => b[0].length - a[0].length)) {
    if (t.includes(name)) {
      let diff = (wd - base.getDay() + 7) % 7;
      if (diff === 0) diff = 7;
      return new Date(base.getTime() + diff * 86400000);
    }
  }
  return null;
}

function findPrize(raw) {
  const m = raw.match(/\b(?:prize|prizes|reward|winner gets|winner receives|récompense|recompense|prix|le gagnant (?:reçoit|recoit|gagne)|igihembo|uzatsinda azahabwa)\s*[:\-–]?\s*([^\n.;]{2,80})/i);
  return m ? m[1].trim() : null;
}

const slugify = (s) => (s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 50);

// Returns the draft plus, for each field, whether it was read from the text or filled in by default.
export function parseBrief(raw, now = new Date()) {
  const text = (raw || "").toLowerCase().replace(/[’`]/g, "'");
  const found = {};
  const name = findName(raw || "");
  const size = findSize(text);
  const format = findFormat(text);
  const advance = findAdvance(text);
  const rounds = findRounds(text);
  const speed = findSpeed(text);
  const prize = findPrize(raw || "");
  const date = findDate(text, now);
  const time = findTime(text);

  let starts = null;
  if (date || time) {
    const d = date ? new Date(date) : new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const [h, mi] = time || [18, 0];
    d.setHours(h, mi, 0, 0);
    if (!date && d <= now) d.setDate(d.getDate() + 1);   // a time alone means the next time it comes round
    starts = d;
  }

  found.name = !!name; found.size = !!size; found.format = !!format; found.advance = !!advance;
  found.rounds = !!rounds; found.speed = !!speed; found.prize = !!prize; found.starts = !!starts;

  const draft = {
    name: name || "",
    slug: slugify(name),
    size: size || 8,
    format: format || recommendFormat(size || 8),
    advance: advance || (format === "league_knockout" || (!format && recommendFormat(size || 8) === "league_knockout") ? 4 : null),
    rounds: rounds || null,
    speed: speed || "standard",
    prize: prize || "",
    starts_at: starts,
  };
  return { draft, found };
}
