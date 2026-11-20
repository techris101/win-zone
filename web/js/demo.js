// Sample data shown only when the live backend is not configured. Clearly labelled in the UI.
const P = {
  p1: "Zuba", p2: "Ineza", p3: "Mugisha10", p4: "Kayitesi", p5: "Habyari", p6: "Uwase", p7: "Ndayi", p8: "Gashugi",
};
const profiles = Object.fromEntries(Object.entries(P).map(([id, username]) => [id, { id, username, display_name: username }]));

const at = (h) => new Date(Date.now() + h * 3600000).toISOString();

function f(tid, stage, round, slot, a, b, sa, sb, status, extra = {}) {
  return { id: `${tid}-${stage}-${round}-${slot}`, tournament_id: tid, stage, round, slot, player_a_id: a, player_b_id: b,
    score_a: sa, score_b: sb, pen_a: null, pen_b: null, status, winner_id: status === "completed" ? (sa > sb ? a : sa < sb ? b : (extra.winner ?? null)) : null,
    scheduled_at: extra.at ?? null, ...extra };
}

const cup = "demo-cup", lg = "demo-league";
const tournaments = [
  { id: cup, slug: "sample-cup", name: "Sample Cup", format: "knockout", size: 8, status: "live", starts_at: at(-30),
    prize_description: "Sample prize", champion_id: null, game: { name: "Football 1v1" }, entries: [{ count: 8 }] },
  { id: lg, slug: "sample-league", name: "Sample League", format: "league_knockout", size: 8, league_advance: 2, status: "live", starts_at: at(-60),
    prize_description: null, champion_id: null, game: { name: "Football 1v1" }, entries: [{ count: 4 }] },
];

const fixtures = {
  [cup]: [
    f(cup, "knockout", 1, 1, "p1", "p2", 2, 1, "completed"), f(cup, "knockout", 1, 2, "p3", "p4", 0, 3, "completed"),
    f(cup, "knockout", 1, 3, "p5", "p6", 1, 0, "completed"), f(cup, "knockout", 1, 4, "p7", "p8", 1, 1, "completed", { pen_a: 4, pen_b: 5, winner: "p8" }),
    f(cup, "knockout", 2, 1, "p1", "p4", 3, 2, "completed"), f(cup, "knockout", 2, 2, "p5", "p8", null, null, "active", { at: at(-0.2) }),
    f(cup, "knockout", 3, 1, "p1", null, null, null, "scheduled"),
  ],
  [lg]: [
    f(lg, "league", 1, 1, "p1", "p2", 2, 0, "completed"), f(lg, "league", 1, 2, "p3", "p4", 1, 1, "completed"),
    f(lg, "league", 2, 1, "p1", "p3", 1, 0, "completed"), f(lg, "league", 2, 2, "p4", "p2", 0, 2, "completed"),
    f(lg, "league", 3, 1, "p1", "p4", null, null, "scheduled", { at: at(20) }), f(lg, "league", 3, 2, "p2", "p3", null, null, "scheduled", { at: at(20.5) }),
  ],
};
// fix pen winner display
fixtures[cup][3].winner_id = "p8";

const entries = {
  [cup]: Object.keys(P).map((id, i) => ({ user_id: id, seed: i + 1, status: "registered" })),
  [lg]: ["p1", "p2", "p3", "p4"].map((id, i) => ({ user_id: id, seed: i + 1, status: "registered" })),
};

const tables = {
  [lg]: [
    { user_id: "p1", played: 2, won: 2, drawn: 0, lost: 0, gf: 3, ga: 0, gd: 3, points: 6, rank: 1 },
    { user_id: "p2", played: 2, won: 1, drawn: 0, lost: 1, gf: 2, ga: 2, gd: 0, points: 3, rank: 2 },
    { user_id: "p4", played: 2, won: 0, drawn: 1, lost: 1, gf: 1, ga: 3, gd: -2, points: 1, rank: 3 },
    { user_id: "p3", played: 2, won: 0, drawn: 1, lost: 1, gf: 1, ga: 2, gd: -1, points: 1, rank: 4 },
  ],
};

export const DEMO = { tournaments, fixtures, entries, tables, profiles };
