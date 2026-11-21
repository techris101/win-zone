// Single data layer. Talks to Supabase when configured, otherwise serves clearly labelled sample data.
import { CONFIG } from "./config.js";
import { DEMO } from "./demo.js";

export const LIVE = Boolean(CONFIG.SUPABASE_URL && CONFIG.SUPABASE_ANON_KEY);
const SB_SRC = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";

let _client = null;
export async function sb() {
  if (!LIVE) throw new Error("not_connected");
  if (_client) return _client;
  const { createClient } = await import(SB_SRC);
  _client = createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true } });
  return _client;
}
const ok = ({ data, error }) => {
  if (error) {
    // The database exists but the WIN ZONE tables have not been created yet.
    if (error.code === "PGRST205" || /schema cache/i.test(error.message || "")) throw new Error("not_ready");
    throw new Error(error.message);
  }
  return data;
};
const NOT_CONNECTED = () => { throw new Error("not_connected"); };

// ------------------------------------------------------------------ public reads
const TSEL = "id,slug,name,format,size,league_advance,status,starts_at,prize_description,champion_id,schedule_tz,slot_hour,round_gap_hours,schedule_speed,phase_rounds,is_demo,game:games(name),entries:tournament_entries(count)";

export async function listTournaments() {
  if (!LIVE) return DEMO.tournaments;
  const c = await sb();
  const rows = ok(await c.from("tournaments").select(TSEL).order("created_at", { ascending: false }).limit(60));
  const rank = { live: 0, open: 1, completed: 2, cancelled: 3, draft: 4 };
  return rows.sort((a, b) => (rank[a.status] ?? 9) - (rank[b.status] ?? 9));
}

export async function getTournament(slug) {
  if (!LIVE) return DEMO.tournaments.find((t) => t.slug === slug) || null;
  const c = await sb();
  return ok(await c.from("tournaments").select(TSEL).eq("slug", slug).maybeSingle());
}

export async function getTournamentData(t) {
  if (!LIVE) {
    return { entries: DEMO.entries[t.id] || [], fixtures: DEMO.fixtures[t.id] || [], table: DEMO.tables[t.id] || [], profiles: DEMO.profiles };
  }
  const c = await sb();
  const [entries, fixtures] = await Promise.all([
    c.from("tournament_entries").select("user_id,seed,status,group_no").eq("tournament_id", t.id).neq("status", "withdrawn").then(ok),
    c.from("fixtures").select("*").eq("tournament_id", t.id).order("round").order("slot").then(ok),
  ]);
  const table = t.format === "knockout" ? []
    : t.format === "groups_knockout" ? ok(await c.rpc("group_tables", { p_tid: t.id }))
    : ok(await c.rpc("league_table", { p_tid: t.id }));
  const profiles = await getProfiles([...entries.map((e) => e.user_id), ...fixtures.flatMap((x) => [x.player_a_id, x.player_b_id])]);
  return { entries, fixtures, table, profiles };
}

export async function getProfiles(ids) {
  const uniq = [...new Set(ids.filter(Boolean))];
  if (!LIVE) return DEMO.profiles;
  if (!uniq.length) return {};
  const c = await sb();
  const rows = ok(await c.from("profiles").select("id,username,display_name,team_name").in("id", uniq));
  return Object.fromEntries(rows.map((r) => [r.id, r]));
}

// Live updates. Returns an unsubscribe function. Pages also poll as a safety net.
export async function subscribe(tid, onChange) {
  if (!LIVE) return () => {};
  const c = await sb();
  const ch = c.channel(`t-${tid}`)
    .on("postgres_changes", { event: "*", schema: "public", table: "fixtures", filter: `tournament_id=eq.${tid}` }, onChange)
    .on("postgres_changes", { event: "*", schema: "public", table: "tournaments", filter: `id=eq.${tid}` }, onChange)
    .on("postgres_changes", { event: "*", schema: "public", table: "tournament_entries", filter: `tournament_id=eq.${tid}` }, onChange)
    .subscribe();
  return () => c.removeChannel(ch);
}

// ------------------------------------------------------------------ auth
export async function getUser() {
  if (!LIVE) return null;
  const c = await sb();
  const { data } = await c.auth.getSession();
  return data.session?.user ?? null;
}
export async function signUp({ email, password, username, country }) {
  if (!LIVE) NOT_CONNECTED();
  const c = await sb();
  return ok(await c.auth.signUp({ email, password, options: { data: { username, display_name: username, country, lang: (typeof localStorage !== "undefined" && localStorage.getItem("wz_lang")) || "en" } } }));
}
export async function signIn({ email, password }) {
  if (!LIVE) NOT_CONNECTED();
  const c = await sb();
  return ok(await c.auth.signInWithPassword({ email, password }));
}
// Forgot password: Supabase emails a link that opens /reset.html already signed in for this one purpose.
export async function sendPasswordReset(email) {
  if (!LIVE) NOT_CONNECTED();
  const c = await sb();
  return ok(await c.auth.resetPasswordForEmail(email, { redirectTo: `${location.origin}/reset.html` }));
}
export async function setNewPassword(password) {
  if (!LIVE) NOT_CONNECTED();
  const c = await sb();
  return ok(await c.auth.updateUser({ password }));
}
export async function signOut() { if (!LIVE) return; const c = await sb(); await c.auth.signOut(); }
export async function rpc(name, args = {}) { const c = await sb(); return ok(await c.rpc(name, args)); }
export async function isOrganizer() { if (!LIVE) return false; try { return Boolean(await rpc("is_organizer")); } catch { return false; } }
export async function isAdmin() { if (!LIVE) return false; try { return Boolean(await rpc("is_admin")); } catch { return false; } }

// ------------------------------------------------------------------ country and local time
export async function listCountries() {
  if (!LIVE) return DEMO.countries;
  const c = await sb();
  return ok(await c.from("countries").select("code,name,tz,blocked").order("name"));
}
export const myProfile = () => rpc("my_profile");
export const setMyCountry = (code) => rpc("set_my_country", { p_code: code });

// ------------------------------------------------------------------ player
export const register = (tid) => rpc("register_for_tournament", { p_tid: tid });
export const withdraw = (tid) => rpc("withdraw_from_tournament", { p_tid: tid });

export async function myEntryIds(uid) {
  const c = await sb();
  const rows = ok(await c.from("tournament_entries").select("tournament_id").eq("user_id", uid).neq("status", "withdrawn"));
  return new Set(rows.map((r) => r.tournament_id));
}
export async function myEntries(uid) {
  const c = await sb();
  return ok(await c.from("tournament_entries").select("status,tournament:tournaments(id,name,slug,status,starts_at,format)").eq("user_id", uid).neq("status", "withdrawn"));
}
export async function myFixtures(uid) {
  const c = await sb();
  return ok(await c.from("fixtures")
    .select("id,stage,round,scheduled_at,status,player_a_id,player_b_id,tournament:tournaments(name,slug)")
    .or(`player_a_id.eq.${uid},player_b_id.eq.${uid}`).in("status", ["scheduled", "active", "stalled"])
    .not("player_a_id", "is", null).not("player_b_id", "is", null).order("scheduled_at", { ascending: true, nullsFirst: false }));
}
export const createHandoff = (fid) => rpc("create_app_handoff", { p_fixture_id: fid });
export const joinFixture = (fid) => rpc("app_join_fixture", { p_fixture_id: fid });
export const submitRoomCode = (fid, code) => rpc("submit_room_code", { p_fixture_id: fid, p_room_code: code, p_capture_method: "manual" });
export const reportHostBlocked = (fid, reason) => rpc("report_host_blocked", { p_fixture_id: fid, p_reason: reason });
export const openDispute = (fid, note) => rpc("open_dispute", { p_fixture_id: fid, p_note: note });

// ------------------------------------------------------------------ organizer / admin
export async function listManaged() {
  const c = await sb();
  return ok(await c.from("tournaments").select(TSEL + ",created_by").order("created_at", { ascending: false }));
}
export const createTournament = (a) => rpc("create_tournament", {
  p_name: a.name, p_slug: a.slug, p_game_slug: "football-1v1", p_format: a.format, p_size: a.size,
  p_starts_at: a.starts_at || null, p_prize: a.prize || null, p_league_advance: a.advance || 4,
});
export const setTournamentStatus = (tid, status) => rpc("set_tournament_status", { p_tid: tid, p_status: status });
export const generateTournament = (tid) => rpc("generate_tournament", { p_tid: tid });
export const scheduleFixtures = (tid, stage, round, start, spacing) =>
  rpc("schedule_fixtures", { p_tid: tid, p_stage: stage, p_round: round, p_start: start, p_spacing_minutes: spacing });
export const resolveFixture = (fid, outcome, notes) => rpc("resolve_fixture", { p_fixture_id: fid, p_outcome: outcome, p_notes: notes });

export async function listAttention() {
  const c = await sb();
  const FXSEL = "id,stage,round,status,score_a,score_b,player_a_id,player_b_id,tournament:tournaments(name,slug)";
  const fx = ok(await c.from("fixtures").select(FXSEL).in("status", ["disputed", "stalled"]));
  // finished matches that a player has asked to be checked
  const open = ok(await c.from("disputes").select("fixture_id,note,user_id,created_at").eq("status", "open"));
  const extra = [...new Set(open.map((d) => d.fixture_id))].filter((id) => !fx.some((x) => x.id === id));
  if (extra.length) fx.push(...ok(await c.from("fixtures").select(FXSEL).in("id", extra)));
  if (!fx.length) return { fixtures: [], reasons: {}, profiles: {}, notes: {}, evidence: {} };
  const evid = ok(await c.from("dispute_evidence").select("fixture_id,user_id,path,note,created_at").in("fixture_id", fx.map((x) => x.id)));
  const evidence = {}, notes = {};
  for (const e of evid) (evidence[e.fixture_id] ||= []).push(e);
  for (const d of open) (notes[d.fixture_id] ||= []).push(d);
  const ev = ok(await c.from("match_events").select("fixture_id,event_type,details,created_at").in("fixture_id", fx.map((x) => x.id)).order("created_at", { ascending: false }));
  const reasons = {};
  for (const e of ev) if (!reasons[e.fixture_id] && (e.details?.reason || e.event_type === "stalled")) reasons[e.fixture_id] = e.details?.reason || e.event_type;
  const profiles = await getProfiles(fx.flatMap((x) => [x.player_a_id, x.player_b_id]));
  return { fixtures: fx, reasons, profiles, notes, evidence };
}

export const publishTournament = (tid) => rpc("publish_tournament", { p_tid: tid });
export const reopenRegistration = (tid) => rpc("reopen_registration", { p_tid: tid });
export const updateTournament = (tid, patch) => rpc("update_tournament", { p_tid: tid, p_patch: patch });
export const rescheduleFixture = (fid, at) => rpc("reschedule_fixture", { p_fixture_id: fid, p_at: at });
export const listAdmins = () => rpc("list_admins");
export const addRole = (who, role) => rpc("add_role", { p_identifier: who, p_role: role });
export const removeRole = (uid, role) => rpc("remove_role", { p_user_id: uid, p_role: role });
export async function editableFixtures(tid) {
  const c = await sb();
  return ok(await c.from("fixtures").select("id,stage,round,slot,status,scheduled_at,player_a_id,player_b_id")
    .eq("tournament_id", tid).order("scheduled_at", { nullsFirst: false }).order("round").order("slot"));
}

// ------------------------------------------------------------------ notifications
export async function myNotifications(limit = 40) {
  const c = await sb();
  return ok(await c.from("notifications").select("id,kind,title,body,url,actions,tournament_id,created_at,read_at")
    .order("created_at", { ascending: false }).limit(limit));
}
export async function unreadCount() {
  if (!LIVE) return 0;
  const c = await sb();
  const { count, error } = await c.from("notifications").select("id", { count: "exact", head: true }).is("read_at", null);
  if (error) return 0;
  return count || 0;
}
export async function myFollows() {
  const c = await sb();
  return ok(await c.from("tournament_follows").select("tournament_id,state"));
}
export const markAllRead = () => rpc("mark_notifications_read", { p_ids: null });
export const setFollow = (tid, follow) => rpc("set_follow", { p_tid: tid, p_follow: follow });
export const savePush = (endpoint, p256dh, auth, ua) => rpc("save_push_subscription", { p_endpoint: endpoint, p_p256dh: p256dh, p_auth: auth, p_ua: ua });
export const deletePush = (endpoint) => rpc("delete_push_subscription", { p_endpoint: endpoint });
export const setMyLang = (lang) => rpc("set_my_lang", { p_lang: lang });
export async function onMyNotification(uid, cb) {
  if (!LIVE) return () => {};
  const c = await sb();
  const ch = c.channel(`n-${uid}`).on("postgres_changes", { event: "INSERT", schema: "public", table: "notifications", filter: `user_id=eq.${uid}` }, (p) => cb(p.new)).subscribe();
  return () => c.removeChannel(ch);
}

// ------------------------------------------------------------------ statistics
export async function liveScores(tid) { if (!LIVE) return []; return rpc("live_scores", { p_tid: tid }); }
export async function playerStats(tid) { if (!LIVE) return []; return rpc("player_stats", { p_tid: tid }); }
export async function leaders(tid, kind, limit = 10) { if (!LIVE) return []; return rpc("footballer_leaders", { p_tid: tid, p_kind: kind, p_limit: limit }); }
export async function careerStats(uid) { if (!LIVE) return null; return rpc("career_stats", { p_user: uid }); }

// ------------------------------------------------------------------ players
export async function rankings(search = null, limit = 200) { if (!LIVE) return []; return rpc("rankings", { p_limit: limit, p_search: search || null }); }
export async function publicPlayer(username) { if (!LIVE) return { ok: false, reason: "not_connected" }; return rpc("public_player", { p_username: username }); }
export const setMyTeamName = (name) => rpc("set_my_team_name", { p_name: name });

// ------------------------------------------------------------------ account and safety
export async function changePassword(email, current, next) {
  const c = await sb();
  const check = await c.auth.signInWithPassword({ email, password: current });
  if (check.error) throw new Error("wrong_current_password");
  return ok(await c.auth.updateUser({ password: next }));
}
export const takeBreak = (days) => rpc("take_break", { p_days: days });
export const setPlayLimit = (max) => rpc("set_play_limit", { p_max: max });
export const deleteMyAccount = (confirm) => rpc("delete_my_account", { p_confirm: confirm });
export const reportPlayer = (username, reason, details, fixtureId) =>
  rpc("report_player", { p_username: username, p_reason: reason, p_details: details || null, p_fixture_id: fixtureId || null });
export async function fixtureBasics(fid) {
  const c = await sb();
  return ok(await c.from("fixtures").select("id,status,completed_at,player_a_id,player_b_id,tournament_id").eq("id", fid).maybeSingle());
}
export async function uploadEvidence(fid, uid, file, note) {
  const c = await sb();
  const ext = ({ "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" })[file.type];
  if (!ext) throw new Error("Use a PNG, JPG or WEBP screenshot.");
  if (file.size > 5 * 1024 * 1024) throw new Error("The file is larger than 5 MB.");
  const path = `${fid}/${uid}/${Date.now()}.${ext}`;
  ok(await c.storage.from("evidence").upload(path, file, { contentType: file.type, upsert: false }));
  return rpc("add_dispute_evidence", { p_fixture_id: fid, p_path: path, p_note: note || null });
}
export async function myEvidence(fid) {
  const c = await sb();
  return ok(await c.from("dispute_evidence").select("path,note,created_at").eq("fixture_id", fid).order("created_at"));
}
export async function evidenceUrl(path) {
  const c = await sb();
  const r = ok(await c.storage.from("evidence").createSignedUrl(path, 600));
  return r.signedUrl;
}

// ------------------------------------------------------------------ sponsors
export async function sponsorsFor(tid) {
  if (!LIVE) return [];
  const c = await sb();
  const rows = ok(await c.from("sponsor_placements").select("placement_type,display_order,sponsor:sponsors(id,name,logo_url,website,active)").eq("tournament_id", tid).order("display_order"));
  return rows.filter((r) => r.sponsor && r.sponsor.active);
}
export async function homeSponsors() {
  if (!LIVE) return [];
  const c = await sb();
  return ok(await c.from("sponsors").select("id,name,logo_url,website").eq("show_on_home", true).eq("active", true).order("name"));
}
export async function allSponsors() {
  const c = await sb();
  return ok(await c.from("sponsors").select("id,name,logo_url,website,active,show_on_home,placements:sponsor_placements(tournament_id,placement_type)").order("name"));
}
export const saveSponsor = (s) => rpc("save_sponsor", { p_id: s.id || null, p_name: s.name, p_logo_url: s.logo_url || null, p_website: s.website || null, p_active: s.active, p_show_on_home: s.show_on_home });
export const setSponsorPlacement = (tid, sid, type, on) => rpc("set_sponsor_placement", { p_tid: tid, p_sponsor: sid, p_type: type, p_on: on });
export const deleteSponsor = (id) => rpc("delete_sponsor", { p_id: id });
export async function uploadSponsorLogo(file) {
  const c = await sb();
  const ext = ({ "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" })[file.type];
  if (!ext) throw new Error("Use a PNG, JPG or WEBP logo.");
  if (file.size > 1024 * 1024) throw new Error("The logo must be 1 MB or smaller.");
  const path = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
  ok(await c.storage.from("sponsor-logos").upload(path, file, { contentType: file.type }));
  return c.storage.from("sponsor-logos").getPublicUrl(path).data.publicUrl;
}

// ------------------------------------------------------------------ admin: safety and demo
export const listReports = (status = "open") => rpc("list_reports", { p_status: status });
export const reviewReport = (id, status) => rpc("review_report", { p_id: id, p_status: status });
export const banPlayer = (username, days, reason) => rpc("ban_player", { p_username: username, p_days: days, p_reason: reason });
export const unbanPlayer = (username) => rpc("unban_player", { p_username: username });
export const listBanned = () => rpc("list_banned");
export const setCountryBlocked = (code, blocked) => rpc("set_country_blocked", { p_code: code, p_blocked: blocked });
export const createDemo = (name, size, format) => rpc("create_demo_tournament", { p_name: name, p_size: size, p_format: format || null });
export const deleteDemo = (tid) => rpc("delete_demo_tournament", { p_tid: tid });
