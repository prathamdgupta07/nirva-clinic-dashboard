// Protected dashboard booking entry point.
//
// The browser supplies only appointment data.  The staff identity is always
// resolved from the verified Supabase Auth bearer token; it is never accepted
// from the request body.
import {
  getClient,
  invokeAppointmentRpc,
  normalizeAppointmentDateTime,
  normalizeAppointmentPhone,
  normalizePatientName,
  resolveIdempotencyKey,
} from "./_shared/appointment.ts";

interface StaffBookingBody {
  doctor_name?: unknown;
  patient_name?: unknown;
  phone_number?: unknown;
  phone_region?: unknown;
  appointment_datetime?: unknown;
  idempotency_key?: unknown;
}

// Keep this explicit: these endpoints handle patient records and must never
// accept requests from arbitrary websites.
const ALLOWED_ORIGINS = new Set([
  "http://127.0.0.1:3000",
  "http://localhost:3000",
  "http://localhost:4173",
  "https://nirva-dashboard-staging.vercel.app",
  "https://nirva-riya-bolna-test.vercel.app",
  "https://nirva-riya-sarvam-test.vercel.app",
]);

function corsHeaders(req: Request): HeadersInit {
  const origin = req.headers.get("origin") || "";
  return {
  // Use an explicit allow-list; this endpoint handles patient records.
  ...(ALLOWED_ORIGINS.has(origin) ? { "Access-Control-Allow-Origin": origin } : {}),
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Vary": "Origin",
  };
}

function response(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders(req) });
}

/** Deliberately stable and PII-free errors for a patient-data endpoint. */
function failure(req: Request, code: string, status: number): Response {
  return response(req, { success: false, error_code: code, resultText: "We could not save that booking." }, status);
}

function bearerToken(req: Request): string | null {
  const value = req.headers.get("authorization") || "";
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() || null;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (origin && !ALLOWED_ORIGINS.has(origin)) return failure(req, "origin_not_allowed", 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req) });
  if (req.method !== "POST") return failure(req, "method_not_allowed", 405);

  // verify_jwt=true is configured at deployment. getUser(token) additionally
  // derives the immutable Auth user id for the database audit record.
  const token = bearerToken(req);
  if (!token) return failure(req, "unauthorized", 401);
  const admin = getClient();
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  const actorUserId = userData.user?.id;
  if (userError || !actorUserId) return failure(req, "unauthorized", 401);

  let body: StaffBookingBody;
  try {
    body = await req.json();
  } catch {
    return failure(req, "invalid_request", 400);
  }

  const patientName = normalizePatientName(body.patient_name);
  const phone = normalizeAppointmentPhone(body.phone_number, body.phone_region ?? "IN");
  const doctorName = typeof body.doctor_name === "string" ? body.doctor_name.trim() : "";
  const appointment = normalizeAppointmentDateTime(body.appointment_datetime);
  // A client-generated UUID is retained for a retry. Generating a fresh one
  // here would defeat duplicate protection after a network interruption.
  const idempotencyKey = await resolveIdempotencyKey(body.idempotency_key, null);
  if (!patientName || !phone.ok || !doctorName || !appointment.ok || !idempotencyKey) {
    return failure(req, "invalid_request", 400);
  }

  try {
    const result = await invokeAppointmentRpc(admin, "staff_book_appointment_v1", {
      p_actor_user_id: actorUserId,
      p_patient_name: patientName,
      p_phone_e164: phone.e164,
      p_doctor_name: doctorName,
      p_appointment_time: appointment.timestamptz,
      p_idempotency_key: idempotencyKey,
      p_booking_window_days: 30,
    });

    // Never echo patient identity back into a browser response. The dashboard
    // already has the submitted identity and only needs operation state.
    return response(req, {
      success: result.success === true,
      booking_success: result.success === true,
      error_code: result.error_code || null,
      resultText: result.success ? "Appointment booked." : "We could not save that booking.",
      booking_id: typeof result.booking_id === "string" ? result.booking_id : null,
      status: typeof result.status === "string" ? result.status : null,
      appointment_time: typeof result.appointment_time_india === "string" ? result.appointment_time_india : null,
      doctor_name: typeof result.canonical_doctor_name === "string" ? result.canonical_doctor_name : null,
    }, result.success ? 200 : 409);
  } catch (error) {
    // Log only operation context; error details may contain database values.
    console.error("staff-book-appointment failed", { actorUserId, errorName: error instanceof Error ? error.name : "unknown" });
    return failure(req, "operation_failed", 500);
  }
});
