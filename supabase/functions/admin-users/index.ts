// Translation Manager — Admin-only user management (Supabase Edge Function "admin-users").
// The app's Users page calls this to list people, invite someone, change their permission or
// remove them. Inviting and removing need the service-role key, which only exists here on the
// server (Supabase provides it to the function); the browser never sees it.
//
// Every request must come from a signed-in user whose email is the 'owner' (Admin) row in
// public.app_roles. Permissions: 'editor' can change translations, 'viewer' is read only.
// Read-only is enforced by row-level security on public.locales, not just hidden in the UI.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const ROLES = ["editor", "viewer"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);

  // the legacy service-role key, or the newer secret key on projects that only have those
  let serverKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!serverKey) {
    try { serverKey = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default ?? ""; } catch { /* none */ }
  }
  if (!serverKey) return reply({ error: "The server isn't configured (no secret key)." }, 500);
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    serverKey,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  // who is calling?
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: who, error: whoErr } = await admin.auth.getUser(jwt);
  const me = who?.user?.email?.toLowerCase();
  if (whoErr || !me) return reply({ error: "Please sign in again." }, 401);
  const { data: mine } = await admin.from("app_roles").select("role").eq("email", me).maybeSingle();
  if (mine?.role !== "owner") return reply({ error: "Only the Admin can manage users." }, 403);

  let body: { action?: string; email?: string; role?: string; redirectTo?: string };
  try { body = await req.json(); } catch { return reply({ error: "Bad request." }, 400); }
  const action = body.action ?? "";
  const email = String(body.email ?? "").trim().toLowerCase();

  async function findUser(e: string) {
    for (let page = 1; page < 50; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) throw error;
      const hit = data.users.find((u) => (u.email ?? "").toLowerCase() === e);
      if (hit || data.users.length < 1000) return hit ?? null;
    }
    return null;
  }

  try {
    if (action === "list") {
      const { data: roles, error: rErr } = await admin.from("app_roles").select("email,role");
      if (rErr) throw rErr;
      const roleOf = new Map((roles ?? []).map((r) => [r.email, r.role]));
      const users = [];
      for (let page = 1; page < 50; page++) {
        const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
        if (error) throw error;
        users.push(...data.users);
        if (data.users.length < 1000) break;
      }
      const seen = new Set<string>();
      const people = users.filter((u) => u.email).map((u) => {
        const e = u.email!.toLowerCase();
        seen.add(e);
        return {
          email: e,
          role: roleOf.get(e) ?? "viewer",
          invited_at: u.invited_at ?? null,
          last_sign_in_at: u.last_sign_in_at ?? null,
          confirmed: !!(u.email_confirmed_at ?? u.confirmed_at),
        };
      });
      // roles set for people who don't have an account (yet)
      for (const [e, role] of roleOf) {
        if (!seen.has(e)) people.push({ email: e, role, invited_at: null, last_sign_in_at: null, confirmed: false });
      }
      people.sort((a, b) => (a.role === "owner" ? -1 : b.role === "owner" ? 1 : a.email.localeCompare(b.email)));
      return reply({ people });
    }

    if (!EMAIL_RE.test(email)) return reply({ error: "Enter a valid email address." }, 400);
    const { data: target } = await admin.from("app_roles").select("role").eq("email", email).maybeSingle();
    if (target?.role === "owner") return reply({ error: "The Admin's own access can't be changed here." }, 400);

    if (action === "invite" || action === "role") {
      const role = String(body.role ?? "");
      if (!ROLES.includes(role)) return reply({ error: "Choose Can edit or Read only." }, 400);
      const { error: upErr } = await admin.from("app_roles").upsert({ email, role }, { onConflict: "email" });
      if (upErr) throw upErr;
      if (action === "role") return reply({ ok: true });

      const { error: invErr } = await admin.auth.admin.inviteUserByEmail(email, {
        redirectTo: body.redirectTo || undefined,
      });
      if (invErr) {
        // someone who already accepted an invite can't be invited twice; their permission is set anyway
        const msg = invErr.message ?? "";
        if ((invErr as { code?: string }).code === "email_exists" || /already been registered/i.test(msg)) {
          return reply({ ok: true, existing: true });
        }
        return reply({ error: msg || "The invite email couldn't be sent." }, 400);
      }
      return reply({ ok: true, invited: true });
    }

    if (action === "remove") {
      if (email === me) return reply({ error: "You can't remove yourself." }, 400);
      const user = await findUser(email);
      if (user) {
        const { error } = await admin.auth.admin.deleteUser(user.id);
        if (error) throw error;
      }
      const { error: delErr } = await admin.from("app_roles").delete().eq("email", email);
      if (delErr) throw delErr;
      return reply({ ok: true });
    }

    return reply({ error: "Unknown action." }, 400);
  } catch (err) {
    return reply({ error: (err as Error)?.message ?? "Something went wrong." }, 500);
  }
});
