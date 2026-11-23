import {
  appointmentPhoneFailure, checkAuth, enforceWebhookRateLimit, getClient, invokeAppointmentRpc, jsonResponse,
  normalizeAppointmentDateTime, normalizeAppointmentPhone, normalizePatientName, normalizePlatformCallId,
  createVoiceIdempotencyKey, rpcFailure,
} from "./_shared/appointment.ts";

interface CancelBody {
  doctor_name?: string; patient_name?: string; phone_number?: string;
  phone_region?: string;
  existing_appointment_datetime?: string; idempotency_key?: string;
  platform_call_id?: string; source?: string;
}

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;
  let body: CancelBody;
  try { body = await req.json(); } catch {
    return jsonResponse(rpcFailure("cancellation", "I didn't receive a valid request. Please try again."), 400);
  }
  const patientName = normalizePatientName(body.patient_name);
  const phone = normalizeAppointmentPhone(body.phone_number, body.phone_region);
  const doctorName = body.doctor_name?.trim();
  const existing = normalizeAppointmentDateTime(body.existing_appointment_datetime);
  if (!doctorName || !patientName || !existing.ok) {
    return jsonResponse(rpcFailure("cancellation", "Please confirm the patient's name, doctor, phone number, and existing appointment date and time."), 400);
  }
  if (!phone.ok) return jsonResponse(appointmentPhoneFailure("cancellation", phone.reason), 400);
  const platformCallId = normalizePlatformCallId(body.platform_call_id) ?? normalizePlatformCallId(req.headers.get("x-call-id"));
  const idempotencyKey = await createVoiceIdempotencyKey("cancel", [patientName, phone.e164, doctorName.trim().toLowerCase(), existing.timestamptz]);
  try {
    const result = await invokeAppointmentRpc(getClient(), "cancel_appointment_v2", {
      p_patient_name: patientName, p_phone_e164: phone.e164, p_doctor_name: doctorName,
      p_existing_appointment_time: existing.timestamptz,
      p_idempotency_key: idempotencyKey,
      p_platform_call_id: platformCallId, p_source: "ai_agent",
    });
    return jsonResponse({ ...result, cancellation_success: result.success });
  } catch (error) {
    console.error("cancel-appointment error", error);
    return jsonResponse(rpcFailure("cancellation", "Sorry, we could not cancel that appointment. Please try again."), 500);
  }
});
