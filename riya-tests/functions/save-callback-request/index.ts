import { checkAuth, createCallbackFromWebhook, enforceWebhookRateLimit, getClient, jsonResponse, normalizeContactNumber, normalizePatientName, normalizePlatformCallId, createVoiceIdempotencyKey } from "./_shared/appointment.ts";
import { resolveDoctorExact } from "./util.ts";

interface SaveCallbackBody {
  patient_name?: string;
  /** Deprecated compatibility alias. */
  caller_name?: string;
  doctor_name?: string;
  phone_number?: string;
  reason?: string;
  /** UUID supplied by the integration for retry-safe delivery. */
  idempotency_key?: string;
  /** Stable provider call/delivery id; used only when no UUID is available. */
  platform_call_id?: string;
}

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;
  let body: SaveCallbackBody;
  try { body = await req.json(); } catch {
    return jsonResponse({ success: false, callback_saved: false, resultText: "I didn't receive a valid callback request." }, 400);
  }
  const patientName = normalizePatientName(body.patient_name ?? body.caller_name);
  const phone = normalizeContactNumber(body.phone_number);
  if (!patientName || !phone) {
    return jsonResponse({ success: false, callback_saved: false, resultText: "Please confirm the patient's name and phone number." }, 400);
  }
  const platformCallId = normalizePlatformCallId(body.platform_call_id) ?? normalizePlatformCallId(req.headers.get("x-call-id"));
  const deliveryId = await createVoiceIdempotencyKey("callback", [patientName, phone, (body.doctor_name || "").trim().toLowerCase(), (body.reason || "").trim()]);
  try {
    const client = getClient();
    let doctorId: string | null = null;
    if (body.doctor_name?.trim()) {
      const doctor = await resolveDoctorExact(client, body.doctor_name);
      if (!doctor || doctor.active === false) {
        return jsonResponse({ success: false, callback_saved: false, error_code: "doctor_not_found", resultText: "I could not find an active doctor by that name. I have not booked or changed any appointment." }, 400);
      }
      doctorId = doctor.id;
    }
    const saved = await createCallbackFromWebhook(
      deliveryId,
      patientName,
      phone,
      doctorId,
      body.reason?.trim() || null,
    );
    if (!saved) {
      return jsonResponse({ success: true, callback_saved: true, duplicate: true, resultText: "This callback request was already saved." });
    }
    return jsonResponse({
      success: true, callback_saved: true, patient_name: patientName,
      resultText: "Your callback request has been saved. This is a callback request, not an appointment booking.",
    });
  } catch (error) {
    console.error("save-callback-request error", error);
    return jsonResponse({ success: false, callback_saved: false, error_code: "request_failed", resultText: "Sorry, we could not save the callback request. Please try again." }, 500);
  }
});
