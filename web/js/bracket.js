import { esc, nameOf, fmtDate, t } from "./ui.js";

export function roundLabel(round, rounds) {
  const left = rounds - round;
  if (left === 0) return t("rd.final");
  if (left === 1) return t("rd.semi");
  if (left === 2) return t("rd.quarter");
  if (left === 3) return t("rd.r16");
  return `${t("rd.round")} ${round}`;
}

function side(f, which, profiles) {
  const id = which === "A" ? f.player_a_id : f.player_b_id;
  const name = nameOf(profiles, id);
  const done = f.status === "completed" || f.status === "bye";
  const score = which === "A" ? f.score_a : f.score_b;
  const pen = which === "A" ? f.pen_a : f.pen_b;
  const win = done && id && f.winner_id === id;
  const showScore = f.status === "completed" && score != null;
  const showPen = showScore && f.pen_a != null && f.pen_b != null && f.score_a === f.score_b;
  const bye = f.status === "bye" && !id;
  return `<div class="side ${win ? "win" : ""}">
    <span class="who ${name ? "" : "tbd"}">${name ? esc(name) : bye ? "BYE" : "TBD"}</span>
    <span>${showPen ? `<span class="pen">(${pen})</span>` : ""}<span class="sc">${showScore ? esc(score) : ""}</span></span></div>`;
}

export function renderBracket(fixtures, profiles) {
  const ko = fixtures.filter((f) => f.stage === "knockout");
  if (!ko.length) return `<div class="empty">${esc(t("t.nomatches"))}</div>`;
  const rounds = Math.max(...ko.map((f) => f.round));
  const cols = [];
  for (let r = 1; r <= rounds; r++) {
    const list = ko.filter((f) => f.round === r).sort((a, b) => a.slot - b.slot);
    cols.push(`<div class="b-round"><h4>${esc(roundLabel(r, rounds))}</h4><div class="b-matches">${list.map((f) => {
      const live = f.status === "active";
      const foot = live ? `<span class="live-t">● ${esc(t("fx.active"))}</span>` : f.status === "scheduled" && f.scheduled_at ? esc(fmtDate(f.scheduled_at)) : f.status === "bye" ? "" : esc(t("fx." + f.status));
      return `<article class="match ${live ? "live" : ""}">${side(f, "A", profiles)}${side(f, "B", profiles)}
        <div class="match-foot"><span>${foot}</span><span>${f.player_a_id && f.player_b_id ? "" : ""}</span></div></article>`;
    }).join("")}</div></div>`);
  }
  return `<div class="bracket-scroll"><div class="bracket">${cols.join("")}</div></div>`;
}

export function renderTable(rows, profiles, advance = 0) {
  if (!rows.length) return `<div class="empty">${esc(t("t.nomatches"))}</div>`;
  return `<div class="table-wrap"><table class="std"><thead><tr>
    <th>${t("tb.rank")}</th><th>${t("tb.player")}</th><th>${t("tb.p")}</th><th>${t("tb.w")}</th><th>${t("tb.d")}</th><th>${t("tb.l")}</th><th>${t("tb.gd")}</th><th>${t("tb.pts")}</th></tr></thead><tbody>
    ${rows.map((r) => `<tr class="${advance && r.rank <= advance ? "adv" : ""}"><td>${r.rank}</td><td>${esc(nameOf(profiles, r.user_id))}</td>
      <td>${r.played}</td><td>${r.won}</td><td>${r.drawn}</td><td>${r.lost}</td><td>${r.gd > 0 ? "+" : ""}${r.gd}</td><td class="pts">${r.points}</td></tr>`).join("")}
    </tbody></table></div>`;
}

export function renderFixtures(fixtures, profiles) {
  const list = [...fixtures].filter((f) => f.player_a_id && f.player_b_id)
    .sort((a, b) => (a.scheduled_at || "9").localeCompare(b.scheduled_at || "9") || a.round - b.round || a.slot - b.slot);
  if (!list.length) return `<div class="empty">${esc(t("t.nomatches"))}</div>`;
  return `<div class="fx-list">${list.map((f) => {
    const done = f.status === "completed";
    return `<div class="fx"><span class="when">${esc(f.scheduled_at ? fmtDate(f.scheduled_at) : "—")}</span>
      <span class="p r ${done && f.winner_id === f.player_a_id ? "w" : ""}">${esc(nameOf(profiles, f.player_a_id))}</span>
      <span class="score">${done ? `${f.score_a}–${f.score_b}` : "v"}</span>
      <span class="p ${done && f.winner_id === f.player_b_id ? "w" : ""}">${esc(nameOf(profiles, f.player_b_id))}</span>
      <span class="st"><span class="pill ${f.status === "active" ? "live" : ""}">${esc(t("fx." + f.status))}</span></span></div>`;
  }).join("")}</div>`;
}

export function renderPlayers(entries, profiles) {
  if (!entries.length) return `<div class="empty">—</div>`;
  const list = [...entries].sort((a, b) => (a.seed ?? 999) - (b.seed ?? 999));
  return `<div class="players-grid">${list.map((e) => `<div class="pl"><span class="s">${e.seed ?? ""}</span>${esc(nameOf(profiles, e.user_id))}</div>`).join("")}</div>`;
}
