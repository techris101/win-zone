// WIN ZONE push sender. Called by the database (pg_net) right after a notification is stored.
// Sends it to every phone the player turned notifications on for, and forgets phones that are gone.
// Secrets (set in Supabase, never in the repo): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, PUSH_HOOK_SECRET.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT")!, Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const secret = Deno.env.get("PUSH_HOOK_SECRET");
  if (!secret || req.headers.get("x-hook-secret") !== secret) return new Response("forbidden", { status: 403 });

  let id: string | undefined;
  try { id = (await req.json()).notification_id; } catch { /* bad body */ }
  if (!id) return Response.json({ ok: false, reason: "no_id" }, { status: 400 });

  const { data: n } = await sb.from("notifications")
    .select("id,user_id,tournament_id,kind,title,body,url,actions").eq("id", id).maybeSingle();
  if (!n) return Response.json({ ok: false, reason: "not_found" }, { status: 404 });

  const { data: subs } = await sb.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", n.user_id);
  const payload = JSON.stringify({
    id: n.id, title: n.title, body: n.body, url: n.url || "/me.html", tag: n.kind, tid: n.tournament_id, actions: n.actions || [],
  });

  let sent = 0, removed = 0, failed = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 6 * 3600 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { await sb.from("push_subscriptions").delete().eq("id", s.id); removed++; }
      else failed++;
    }
  }
  await sb.from("notifications").update({ pushed_at: new Date().toISOString() }).eq("id", n.id);
  return Response.json({ ok: true, sent, removed, failed });
});
