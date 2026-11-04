// JARVIS account helper. Runs on Supabase's servers, never in the browser.
// Only the teacher account can use it. It creates student accounts,
// resets passwords, and turns accounts on or off.
import { createClient } from "npm:@supabase/supabase-js@2";

let cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-api-version, x-region",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const WORDS = ["maple","rocket","otter","canyon","pixel","falcon","harbor","cobalt","meadow","comet","tiger","lantern","summit","willow","ember","glacier","orbit","prism","saddle","thunder","velvet","acorn","bison","cedar","delta","echo","fjord","garnet","hazel","iris","jasper","koala","lotus","mango","nectar","onyx","pepper","quartz","raven","sierra","tundra","umber","violet","walnut","yarrow","zephyr","basil","cricket","dune","fern"];
function rnd(n: number) { const a = new Uint32Array(1); crypto.getRandomValues(a); return a[0] % n; }
function makePassword() { return `${WORDS[rnd(WORDS.length)]}-${WORDS[rnd(WORDS.length)]}-${10 + rnd(90)}`; }
function makePid() { const c = "abcdefghijkmnpqrstuvwxyz23456789"; let s = "u"; for (let i = 0; i < 9; i++) s += c[rnd(c.length)]; return s; }
const DOMAIN = "jarvis.local";

Deno.serve(async (req) => {
  // Allow whatever headers the browser asks about, so the check before each request never fails
  const asked = req.headers.get("Access-Control-Request-Headers");
  if (asked) cors = { ...cors, "Access-Control-Allow-Headers": asked };
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  // Opening the address in a browser tab shows this, which proves the helper is running
  if (req.method === "GET") return json({ ok: true, helper: "jarvis-admin", note: "Running. JARVIS uses this to create and reset accounts." });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      auth: { persistSession: false },
    });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "Please sign in." }, 401);
    const { data: me } = await admin.from("people").select("role, active").eq("id", user.id).maybeSingle();
    if (!me || me.role !== "teacher" || !me.active) return json({ error: "Only {{teacher}} can do that." }, 403);

    const body = await req.json();

    if (body.action === "create") {
      const results: unknown[] = [];
      for (const s of (body.students ?? []).slice(0, 80)) {
        const username = String(s.username ?? "").toLowerCase().trim();
        const name = String(s.name ?? "").trim().slice(0, 80);
        if (!/^[a-z0-9]{2,30}$/.test(username) || !name) { results.push({ username, name, error: "Needs a name and a username of letters and numbers." }); continue; }
        const password = makePassword();
        const { data: created, error } = await admin.auth.admin.createUser({ email: `${username}@${DOMAIN}`, password, email_confirm: true, user_metadata: { name } });
        if (error || !created.user) { results.push({ username, name, error: /already/i.test(error?.message ?? "") ? "That username is taken." : (error?.message ?? "Couldn’t create it.") }); continue; }
        const role = s.role === "teacher" ? "teacher" : "student";
        const row = { id: created.user.id, pid: makePid(), username, name, role, grad: role === "teacher" ? null : (Number(s.grad) || null), active: true };
        const { error: e2 } = await admin.from("people").insert(row);
        if (e2) { await admin.auth.admin.deleteUser(created.user.id); results.push({ username, name, error: e2.message }); continue; }
        results.push({ username, name, password, pid: row.pid });
      }
      return json({ results });
    }

    if (["reset", "setActive", "setPassword", "rename", "setRole"].includes(body.action)) {
      const { data: p } = await admin.from("people").select("id, username, name, role").eq("pid", String(body.pid)).maybeSingle();
      if (!p) return json({ error: "Student not found." }, 404);
      const self = p.id === user.id;
      if (self && (body.action === "setActive" || body.action === "setRole")) return json({ error: "You can’t change your own role or turn off your own account." }, 400);
      if (body.action === "setRole") {
        const role = body.role === "teacher" ? "teacher" : "student";
        const { error } = await admin.from("people").update(role === "teacher" ? { role, grad: null } : { role }).eq("id", p.id);
        if (error) return json({ error: error.message }, 400);
        return json({ ok: true, role });
      }
      if (body.action === "setPassword") {
        const password = String(body.password ?? "");
        if (password.length < 8) return json({ error: "Passwords need at least 8 characters." }, 400);
        const { error } = await admin.auth.admin.updateUserById(p.id, { password });
        if (error) return json({ error: error.message }, 400);
        return json({ username: p.username, name: p.name, password });
      }
      if (body.action === "rename") {
        const username = String(body.username ?? "").toLowerCase().trim();
        if (!/^[a-z0-9]{2,30}$/.test(username)) return json({ error: "Usernames are 2–30 lowercase letters or numbers." }, 400);
        if (username === p.username) return json({ ok: true, username });
        const { data: taken } = await admin.from("people").select("pid").eq("username", username).maybeSingle();
        if (taken) return json({ error: "That username is taken." }, 400);
        const { error } = await admin.auth.admin.updateUserById(p.id, { email: `${username}@${DOMAIN}`, email_confirm: true });
        if (error) return json({ error: error.message }, 400);
        await admin.from("people").update({ username }).eq("id", p.id);
        return json({ ok: true, username });
      }
      if (body.action === "reset") {
        const password = makePassword();
        const { error } = await admin.auth.admin.updateUserById(p.id, { password });
        if (error) return json({ error: error.message }, 400);
        return json({ username: p.username, name: p.name, password });
      }
      const active = !!body.active;
      const { error } = await admin.auth.admin.updateUserById(p.id, { ban_duration: active ? "none" : "876000h" });
      if (error) return json({ error: error.message }, 400);
      await admin.from("people").update({ active }).eq("id", p.id);
      return json({ ok: true, active });
    }

    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
