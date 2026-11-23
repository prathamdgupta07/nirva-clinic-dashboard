// Password-confirmed doctor leave editor. The password is used only to verify
// the current authenticated user and is never stored, returned, or logged.
import { createClient } from "jsr:@supabase/supabase-js@2.118.0";
import { getClient, invokeAppointmentRpc } from "./_shared/appointment.ts";

const ALLOWED_ORIGINS = new Set([
  "http://127.0.0.1:3000",
  "http://localhost:3000",
  "http://localhost:4173",
  "https://nirva-dashboard-staging.vercel.app",
  "https://nirva-riya-bolna-test.vercel.app",
  "https://nirva-riya-sarvam-test.vercel.app",
]);

function headers(req: Request): HeadersInit {
  const origin = req.headers.get("origin") || "";
  return {
    ...(ALLOWED_ORIGINS.has(origin) ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  };
}

function reply(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: headers(req) });
}

function fail(req: Request, code: string, status: number): Response {
  return reply(req, { success: false, error_code: code }, status);
}

function bearerToken(req: Request): string | null {
  return /^Bearer\s+(.+)$/i.exec(req.headers.get("authorization") || "")?.[1]?.trim() || null;
}

function validDate(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (origin && !ALLOWED_ORIGINS.has(origin)) return fail(req, "origin_not_allowed", 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers(req) });
  if (req.method !== "POST") return fail(req, "method_not_allowed", 405);

  const accessToken = bearerToken(req);
  if (!accessToken) return fail(req, "unauthorized", 401);
  const admin = getClient();
  const { data: userData, error: userError } = await admin.auth.getUser(accessToken);
  const actorUserId = userData.user?.id;
  const email = userData.user?.email;
  if (userError || !actorUserId || !email) return fail(req, "unauthorized", 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail(req, "invalid_request", 400); }
  const leaveId = typeof body.leave_id === "string" ? body.leave_id : "";
  const start = body.leave_start_date;
  const end = body.leave_end_date;
  const reason = typeof body.reason === "string" ? body.reason.slice(0, 500) : null;
  const password = typeof body.password === "string" ? body.password : "";
  if (!leaveId || !validDate(start) || !validDate(end) || start > end || !password) {
    return fail(req, "invalid_request", 400);
  }

  // Verify the supplied password against the current account. Use the
  // publishable key only for this password-auth request; mutations still use
  // the server-only service role through the audited RPC below.
  const url = Deno.env.get("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !publishableKey) return fail(req, "operation_failed", 500);
  const verifier = createClient(url, publishableKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: passwordCheck, error: passwordError } = await verifier.auth.signInWithPassword({ email, password });
  if (passwordError || passwordCheck.user?.id !== actorUserId) return fail(req, "invalid_password", 401);

  try {
    const result = await invokeAppointmentRpc(admin, "update_doctor_leave_v1", {
      p_actor_user_id: actorUserId,
      p_leave_id: leaveId,
      p_leave_start_date: start,
      p_leave_end_date: end,
      p_reason: reason,
    });
    return reply(req, { success: result.success === true, error_code: result.error_code || null }, result.success ? 200 : 409);
  } catch (error) {
    console.error("update-doctor-leave failed", { actorUserId, errorName: error instanceof Error ? error.name : "unknown" });
    return fail(req, "operation_failed", 500);
  }
});
