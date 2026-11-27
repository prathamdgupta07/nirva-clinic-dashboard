import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2.118.0";
import { DateTime } from "npm:luxon@3.5.0";

export { DateTime };

export interface AppointmentResult {
  success: boolean;
  booking_success?: boolean;
  reschedule_success?: boolean;
  cancellation_success?: boolean;
  error_code?: string | null;
  result_text?: string;
  resultText?: string;
  [key: string]: unknown;
}

export function getClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Missing Supabase service configuration");
  return createClient(url, key);
}

/**
 * Verify the signed JWT claims before a service-role mutation. getUser()
 * confirms the account; getClaims(token) verifies the token and exposes its
 * authenticator-assurance level without trusting a client-side decode.
 */
export async function hasVerifiedAal2(client: SupabaseClient, accessToken: string): Promise<boolean> {
  const { data, error } = await client.auth.getClaims(accessToken);
  return !error && data.claims?.aal === "aal2";
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let different = 0;
  for (let index = 0; index < left.length; index += 1) {
    different |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return different === 0;
}

/** Returns the authenticated integration identity without exposing its secret. */
export function webhookSource(req: Request): "vani" | "sarvam" | "bolna" | null {
  const provided = req.headers.get("x-webhook-secret");
  const vaniSecret = Deno.env.get("WEBHOOK_SECRET");
  const sarvamSecret = Deno.env.get("SARVAM_WEBHOOK_SECRET");
  if (!provided) return null;
  if (vaniSecret && constantTimeEqual(provided, vaniSecret)) return "vani";
  if (sarvamSecret && constantTimeEqual(provided, sarvamSecret)) return "sarvam";
  // Riya test projects: Bolna tools send BOLNA_WEBHOOK_SECRET.
  const bolnaSecret = Deno.env.get("BOLNA_WEBHOOK_SECRET");
  if (bolnaSecret && constantTimeEqual(provided, bolnaSecret)) return "bolna";
  return null;
}

/** Reject every request until a shared secret is explicitly configured. */
export function checkAuth(req: Request): Response | null {
  if (!webhookSource(req)) {
    return jsonResponse({ success: false, error_code: "unauthorized", resultText: "Unauthorized." }, 401);
  }
  return null;
}

/**
 * Cap each authenticated provider at 60 requests per minute. This runs after
 * secret validation, so unauthenticated traffic cannot exhaust the database
 * limiter or learn which provider is configured. The database operation is
 * atomic across concurrent Edge Function instances.
 */
export async function enforceWebhookRateLimit(req: Request): Promise<Response | null> {
  const source = webhookSource(req);
  if (!source) return jsonResponse({ success: false, error_code: "unauthorized", resultText: "Unauthorized." }, 401);
  try {
    const { data, error } = await getClient().rpc("consume_webhook_rate_limit", {
      p_source: source,
      p_limit: 60,
    });
    if (error || data !== true) {
      return jsonResponse({ success: false, error_code: "rate_limited", resultText: "Please try again in a minute." }, 429);
    }
  } catch (error) {
    // Fail closed: a public integration must not proceed when its abuse
    // protection cannot be checked. Details stay in server logs only.
    console.error("webhook rate-limit check failed", error);
    return jsonResponse({ success: false, error_code: "temporarily_unavailable", resultText: "Please try again shortly." }, 503);
  }
  return null;
}

export async function createCallbackFromWebhook(
  deliveryId: string,
  callerName: string,
  phoneNumber: string,
  doctorId: string | null,
  reason: string | null,
): Promise<boolean> {
  const { data, error } = await getClient().rpc("create_callback_from_webhook", {
    p_delivery_id: deliveryId,
    p_caller_name: callerName,
    p_phone_number: phoneNumber,
    p_doctor_id: doctorId,
    p_reason: reason,
  });
  if (error || typeof data !== "boolean") {
    console.error("callback webhook write failed", error);
    throw new Error("callback_webhook_write_failed");
  }
  return data;
}

export function normalizePatientName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const name = value.trim().replace(/\s+/g, " ");
  return name.length >= 2 && name.length <= 160 ? name : null;
}

/** Accept the caller's local, landline, or international number as provided. */
export function normalizeContactNumber(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const compact = value.trim().replace(/[\s().-]/g, "");
  if (!compact || !/\d/.test(compact)) return null;
  return compact;
}

export type AppointmentPhoneResult =
  | { ok: true; e164: string }
  | { ok: false; reason: "country_required" | "invalid" };
type AppointmentPhoneFailureReason = "country_required" | "invalid";

/**
 * Appointment identity is stored in E.164 form. An unprefixed 10-digit
 * number defaults to India. Every other number must arrive with its
 * caller-confirmed +country prefix. The backend checks only the E.164 shape:
 * a + followed by 7–15 digits. It does not apply country-specific numbering
 * plan validation after Vani has confirmed the number with the caller.
 */
export function normalizeAppointmentPhone(
  value: unknown,
  regionValue?: unknown,
): AppointmentPhoneResult {
  if (typeof value !== "string" || !value.trim()) return { ok: false, reason: "invalid" };
  const compact = value.trim().replace(/[\s().-]/g, "");
  if (compact.startsWith("+")) {
    return /^\+[1-9][0-9]{6,14}$/.test(compact)
      ? { ok: true, e164: compact }
      : { ok: false, reason: "invalid" };
  }

  if (!/^\d+$/.test(compact)) return { ok: false, reason: "invalid" };
  if (compact.length === 10) return { ok: true, e164: `+91${compact}` };

  // regionValue records Vani's country context, but Vani must add the actual
  // calling code before submitting an international appointment number.
  void regionValue;
  return { ok: false, reason: "country_required" };
}

export function appointmentPhoneFailure(
  operation: "booking" | "reschedule" | "cancellation",
  reason: AppointmentPhoneFailureReason,
): AppointmentResult {
  const successField = operation === "booking"
    ? "booking_success"
    : operation === "reschedule"
    ? "reschedule_success"
    : "cancellation_success";
  const countryRequired = reason === "country_required";
  return {
    success: false,
    [successField]: false,
    error_code: countryRequired ? "phone_country_required" : "invalid_phone_number",
    resultText: countryRequired
      ? "Please confirm which country the number is registered in, then submit it with that country's + calling code. For an Indian landline, ask for its STD code or the full number including that code."
      : "That phone number must start with + and contain 7 to 15 digits. Please ask the caller to repeat or correct it before saving the appointment.",
  };
}

/** @deprecated Use normalizeContactNumber; kept for the staff endpoint transition. */
export const normalizeE164 = normalizeContactNumber;

export function normalizeAppointmentDateTime(
  raw: unknown,
): { ok: true; iso: string; timestamptz: string } | { ok: false } {
  if (!raw || typeof raw !== "string") return { ok: false };
  const trimmed = raw.trim();
  const formats = [
    "yyyy-MM-dd h:mm a", "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm",
    "MMMM d, yyyy h:mm a", "MMMM d, yyyy 'at' h:mm a", "MMM d, yyyy h:mm a",
    "M/d/yyyy h:mm a", "yyyy/MM/dd HH:mm",
  ];
  let dt: DateTime | null = null;
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?([+-]\d{2}:\d{2}|Z)?$/.test(trimmed)) {
    const parsed = DateTime.fromISO(trimmed, { zone: "Asia/Kolkata", setZone: true });
    if (parsed.isValid) dt = parsed.setZone("Asia/Kolkata");
  } else {
    for (const format of formats) {
      const parsed = DateTime.fromFormat(trimmed, format, { zone: "Asia/Kolkata" });
      if (parsed.isValid) { dt = parsed; break; }
    }
  }
  if (!dt || !dt.isValid || dt.second !== 0 || dt.minute % 15 !== 0) return { ok: false };
  return {
    ok: true,
    iso: dt.toFormat("yyyy-MM-dd'T'HH:mm:ss"),
    timestamptz: dt.toUTC().toISO({ suppressMilliseconds: true })!,
  };
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

/**
 * Returns a stable UUID for an operation retry. Do not use a Voice AI tool
 * call ID: providers can reuse it. A stable platform-level call ID is safe as
 * a transitional source when the voice integration cannot send a UUID yet.
 */
export async function resolveIdempotencyKey(
  idempotencyKey: unknown,
  platformCallId: unknown,
): Promise<string | null> {
  if (typeof idempotencyKey === "string" && isUuid(idempotencyKey)) return idempotencyKey;
  if (typeof platformCallId !== "string" || !platformCallId.trim()) return null;
  const digest = new Uint8Array(await crypto.subtle.digest(
    "SHA-256", new TextEncoder().encode(`nirva-appointment-operation:${platformCallId.trim()}`),
  ));
  // Format the first 128 digest bits as an RFC 4122 version-5 compatible UUID.
  digest[6] = (digest[6] & 0x0f) | 0x50;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = [...digest.slice(0, 16)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/**
 * A literal template such as "{{call.id}}" is not a real platform call ID.
 * Some voice providers pass unsupported templates through unchanged, which
 * would make every booking share one idempotency key and cause false clashes.
 */
export function normalizePlatformCallId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const id = value.trim();
  if (!id || /\{\{[^}]+\}\}/.test(id)) return null;
  return id;
}

export async function invokeAppointmentRpc(
  client: SupabaseClient,
  rpcName: string,
  args: Record<string, unknown>,
): Promise<AppointmentResult> {
  const { data, error } = await client.rpc(rpcName, args);
  if (error) throw error;
  const result = (data || {}) as AppointmentResult;
  return {
    ...result,
    success: result.success === true,
    resultText: result.result_text || result.resultText || "We could not complete that request.",
  };
}

export function rpcFailure(operation: "booking" | "reschedule" | "cancellation", message: string): AppointmentResult {
  return {
    success: false,
    [`${operation}_success`]: false,
    error_code: "request_failed",
    resultText: message,
  };
}
