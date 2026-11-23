import { getClient, resolveIdempotencyKey, invokeAppointmentRpc } from "./_shared/appointment.ts";
// Authenticated staff-only callback completion endpoint (STAGED ONLY).

// Only the local preview and the deployed Nirva dashboard may complete a
// callback. Do not replace this allow-list with a wildcard.
const ALLOWED_ORIGINS = new Set([
  "http://127.0.0.1:3000",
  "http://localhost:3000",
  "http://localhost:4173",
  "https://nirva-dashboard-staging.vercel.app",
  "https://nirva-riya-bolna-test.vercel.app",
  "https://nirva-riya-sarvam-test.vercel.app",
]);
function headers(req: Request): HeadersInit { const o = req.headers.get("origin") || ""; return { ...(ALLOWED_ORIGINS.has(o) ? { "Access-Control-Allow-Origin": o } : {}), "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Content-Type": "application/json", "Cache-Control": "no-store", "Vary": "Origin" }; }
function reply(req: Request, body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: headers(req) }); }
function fail(req: Request, code: string, status: number) { return reply(req, { success: false, error_code: code }, status); }

Deno.serve(async (req) => {
  const origin = req.headers.get("origin"); if (origin && !ALLOWED_ORIGINS.has(origin)) return fail(req, "origin_not_allowed", 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers(req) });
  if (req.method !== "POST") return fail(req, "method_not_allowed", 405);
  const raw = /^Bearer\s+(.+)$/i.exec(req.headers.get("authorization") || "")?.[1]?.trim(); if (!raw) return fail(req, "unauthorized", 401);
  const admin = getClient(); const { data, error } = await admin.auth.getUser(raw); const actorUserId = data.user?.id;
  if (error || !actorUserId) return fail(req, "unauthorized", 401);
  let body: Record<string, unknown>; try { body = await req.json(); } catch { return fail(req, "invalid_request", 400); }
  const targetType = typeof body.target_type === "string" ? body.target_type.trim().toLowerCase() : "";
  const targetId = typeof body.target_id === "string" ? body.target_id : "";
  const idempotencyKey = await resolveIdempotencyKey(body.idempotency_key, null);
  if (!targetId || !idempotencyKey || !["call", "callback_request"].includes(targetType)) return fail(req, "invalid_request", 400);
  try {
    const result = await invokeAppointmentRpc(admin, "staff_complete_callback_v1", { p_actor_user_id: actorUserId, p_target_type: targetType, p_target_id: targetId, p_idempotency_key: idempotencyKey });
    return reply(req, { success: result.success === true, error_code: result.error_code || null, status: result.status || null }, result.success ? 200 : 409);
  } catch (caught) {
    console.error("staff-complete-callback failed", { actorUserId, errorName: caught instanceof Error ? caught.name : "unknown" });
    return fail(req, "operation_failed", 500);
  }
});
