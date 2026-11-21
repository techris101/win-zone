// WIN ZONE file cleanup. Called by the database (pg_net) when a finished tournament is tidied up:
// deletes that tournament's dispute screenshots from the private "evidence" storage.
// Files can only be removed through the storage service, not with SQL, which is why this small function exists.
// Uses the same hook secret as send-push (PUSH_HOOK_SECRET), set in Supabase, never in the repo.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const secret = Deno.env.get("PUSH_HOOK_SECRET");
  if (!secret || req.headers.get("x-hook-secret") !== secret) return new Response("forbidden", { status: 403 });

  let paths: string[] = [];
  try { paths = (await req.json()).paths ?? []; } catch { /* bad body */ }
  // only files inside the evidence folders, named <fixture id>/<user id>/<file>
  paths = paths.filter((p) => typeof p === "string" && /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[A-Za-z0-9_.-]{1,80}$/.test(p)).slice(0, 500);
  if (!paths.length) return Response.json({ ok: true, removed: 0 });

  const { data, error } = await sb.storage.from("evidence").remove(paths);
  if (error) return Response.json({ ok: false, reason: error.message }, { status: 500 });
  return Response.json({ ok: true, removed: data?.length ?? 0 });
});
