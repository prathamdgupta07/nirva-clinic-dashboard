import { getClient, resolveIdempotencyKey, invokeAppointmentRpc, normalizeAppointmentDateTime } from "./_shared/appointment.ts";
// Authenticated staff-only booking lifecycle endpoint (STAGED ONLY).

// Explicit production and local origins only; booking lifecycle actions carry
// patient information and must not be callable cross-site.
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
    "Access-Control-Allow-Methods": "POST, OPTIONS", "Content-Type": "application/json",
    "Cache-Control": "no-store", "Vary": "Origin",
  };
}
function reply(req: Request, body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: headers(req) }); }
function fail(req: Request, code: string, status: number) { return reply(req, { success: false, error_code: code }, status); }
function token(req: Request) { return /^Bearer\s+(.+)$/i.exec(req.headers.get("authorization") || "")?.[1]?.trim() || null; }

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  if (origin && !ALLOWED_ORIGINS.has(origin)) return fail(req, "origin_not_allowed", 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers(req) });
  if (req.method !== "POST") return fail(req, "method_not_allowed", 405);
  const accessToken = token(req); if (!accessToken) return fail(req, "unauthorized", 401);
  const admin = getClient();
  const { data, error } = await admin.auth.getUser(accessToken);
  const actorUserId = data.user?.id; if (error || !actorUserId) return fail(req, "unauthorized", 401);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail(req, "invalid_request", 400); }
  const bookingId = typeof body.booking_id === "string" ? body.booking_id : "";
  const action = typeof body.action === "string" ? body.action.trim().toLowerCase() : "";
  const idempotencyKey = await resolveIdempotencyKey(body.idempotency_key, null);
  const newTime = action === "reschedule" ? normalizeAppointmentDateTime(body.new_appointment_datetime) : { ok: true, timestamptz: null };
  if (!bookingId || !idempotencyKey || !newTime.ok) return fail(req, "invalid_request", 400);
  try {
    const result = action === "confirmed"
      ? await invokeAppointmentRpc(admin, "staff_reopen_booking_v1", {
        p_actor_user_id: actorUserId, p_booking_id: bookingId, p_idempotency_key: idempotencyKey,
      })
      : await invokeAppointmentRpc(admin, "staff_update_booking_v1", {
        p_actor_user_id: actorUserId, p_booking_id: bookingId, p_action: action,
        p_idempotency_key: idempotencyKey, p_new_appointment_time: newTime.timestamptz,
      });
    return reply(req, { success: result.success === true, error_code: result.error_code || null,
      booking_id: typeof result.booking_id === "string" ? result.booking_id : null,
      old_booking_id: typeof result.old_booking_id === "string" ? result.old_booking_id : null,
      status: typeof result.status === "string" ? result.status : null }, result.success ? 200 : 409);
  } catch (caught) {
    console.error("staff-appointment-action failed", { actorUserId, errorName: caught instanceof Error ? caught.name : "unknown" });
    return fail(req, "operation_failed", 500);
  }
});
