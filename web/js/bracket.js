import { esc, nameOf, fmtDate, t, playerLink } from "./ui.js";

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

function matchCard(f, profiles) {
  const live = f.status === "active";
  const foot = live ? `<span class="live-t">● ${esc(t("fx.active"))}</span>` : f.status === "scheduled" && f.scheduled_at ? esc(fmtDate(f.scheduled_at)) : f.status === "bye" ? "" : esc(t("fx." + f.status));
  return `<article class="match ${live ? "live" : ""}">${side(f, "A", profiles)}${side(f, "B", profiles)}<div class="match-foot"><span>${foot}</span></div></article>`;
}

export function renderBracket(fixtures, profiles) {
  const ko = fixtures.filter((f) => f.stage === "knockout");
  const po = fixtures.filter((f) => f.stage === "playoff").sort((a, b) => a.slot - b.slot);
  const playoff = po.length ? `<div class="b-playoff"><h4>${esc(t("rd.playoff"))}</h4><div class="b-playoff-grid">${po.map((f) => matchCard(f, profiles)).join("")}</div></div>` : "";
  if (!ko.length) return playoff ? `<div class="bracket-scroll">${playoff}</div>` : `<div class="empty">${esc(t("t.nomatches"))}</div>`;
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
  return `<div class="bracket-scroll">${playoff}<div class="bracket">${cols.join("")}</div></div>`;
}

// zones: { direct: n, playoff: m } -> ranks 1..n qualify, n+1..n+m go to the play-off round
export function renderTable(rows, profiles, advance = 0, zones = null) {
  if (!rows.length) return `<div class="empty">${esc(t("t.nomatches"))}</div>`;
  const zoneOf = (r) => zones ? (r.rank <= zones.direct ? "adv" : r.rank <= zones.direct + zones.playoff ? "po" : "") : (advance && r.rank <= advance ? "adv" : "");
  const legend = zones ? `<p class="mute small zone-legend"><span class="zl adv"></span>${esc(t("t.zdirect"))} <span class="zl po"></span>${esc(t("t.zplayoff"))}</p>` : "";
  return `${legend}<div class="table-wrap"><table class="std"><thead><tr>
    <th>${t("tb.rank")}</th><th>${t("tb.player")}</th><th>${t("tb.p")}</th><th>${t("tb.w")}</th><th>${t("tb.d")}</th><th>${t("tb.l")}</th><th>${t("tb.gd")}</th><th>${t("tb.pts")}</th></tr></thead><tbody>
    ${rows.map((r) => `<tr class="${zoneOf(r)}"><td>${r.rank}</td><td>${playerLink(profiles, r.user_id)}</td>
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
      <span class="p r ${done && f.winner_id === f.player_a_id ? "w" : ""}">${playerLink(profiles, f.player_a_id)}</span>
      <span class="score">${done ? `${f.score_a}–${f.score_b}` : "v"}</span>
      <span class="p ${done && f.winner_id === f.player_b_id ? "w" : ""}">${playerLink(profiles, f.player_b_id)}</span>
      <span class="st"><span class="pill ${f.status === "active" ? "live" : ""}">${esc(t("fx." + f.status))}</span></span></div>`;
  }).join("")}</div>`;
}

export function renderPlayers(entries, profiles) {
  if (!entries.length) return `<div class="empty">—</div>`;
  const list = [...entries].sort((a, b) => (a.seed ?? 999) - (b.seed ?? 999));
  return `<div class="players-grid">${list.map((e) => `<div class="pl"><span class="s">${e.seed ?? ""}</span>${playerLink(profiles, e.user_id)}</div>`).join("")}</div>`;
}

export function groupLetter(n) { return String.fromCharCode(64 + Number(n)); }

export function renderGroups(rows, profiles) {
  if (!rows.length) return `<div class="empty">${esc(t("t.nomatches"))}</div>`;
  const groups = [...new Set(rows.map((r) => r.group_no))].sort((a, b) => a - b);
  return `<div class="groups-grid">${groups.map((g) => `<section class="group"><h4>${esc(t("t.group"))} ${groupLetter(g)}</h4>
    ${renderTable(rows.filter((r) => r.group_no === g).sort((a, b) => a.rank - b.rank), profiles, 2)}</section>`).join("")}</div>`;
}

// same rule as the server: knockout size 16 with 32+ players, 8 with 16+, else 4
export function phaseZones(players) {
  const s = players >= 32 ? 16 : players >= 16 ? 8 : 4;
  return players >= s + s / 2 ? { direct: s / 2, playoff: s } : { direct: Math.min(s, players), playoff: 0 };
}

// plain-language status for a player's row
export function statusText(r, format) {
  if (r.status === "qualified") return format === "league" ? t("s.title") : t("s.qualified");
  if (r.status === "in_race") {
    if (r.needs != null && r.can_secure) return t("s.needs").replace("{n}", r.needs).replace("{left}", r.remaining);
    return t("s.needs_help");
  }
  return t("s." + r.status);
}

export function renderRace(rows, profiles, format) {
  if (!rows.length) return `<div class="empty">${esc(t("s.none"))}</div>`;
  const cls = (st) => (["qualified", "champion", "playoff_sure", "in"].includes(st) ? "ok" : st === "eliminated" ? "out" : st === "finished" ? "" : "race");
  const showTable = rows.some((r) => r.pos != null);
  return `<div class="table-wrap"><table class="std race"><thead><tr>
      <th>${showTable ? t("tb.rank") : ""}</th><th>${t("tb.player")}</th>${showTable ? `<th>${t("tb.pts")}</th><th>${t("s.max")}</th>` : ""}<th>${t("s.form")}</th><th>${t("s.status")}</th></tr></thead><tbody>
    ${rows.map((r) => `<tr><td>${r.pos ?? ""}</td><td>${playerLink(profiles, r.user_id)}${r.group_no ? ` <span class="mute small">${esc(t("t.group"))} ${groupLetter(r.group_no)}</span>` : ""}</td>
      ${showTable ? `<td class="pts">${r.points}</td><td>${r.max_points}</td>` : ""}
      <td class="frm">${(r.form || "").split("").map((c) => `<i class="f-${c}">${c}</i>`).join("")}</td>
      <td class="st"><span class="tag ${cls(r.status)}">${esc(statusText(r, format))}</span></td></tr>`).join("")}
    </tbody></table></div>`;
}

// "Footballer (Team)" leaderboards: the same star can play for many teams
export function renderLeaders(title, rows, valueOf) {
  return `<section class="leaders"><h4>${esc(title)}</h4>${rows.length ? `<ol>${rows.map((r) => `<li>
      <span class="who"><b>${esc(r.footballer)}</b> <span class="team">(${esc(r.team_name || "?")})</span><small>${esc(r.owner_name || "")}</small></span>
      <span class="val">${esc(valueOf(r))}</span></li>`).join("")}</ol>` : `<div class="mute small">${esc(t("s.nodata"))}</div>`}</section>`;
}
