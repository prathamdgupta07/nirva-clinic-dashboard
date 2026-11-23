import {
  appointmentPhoneFailure, checkAuth, enforceWebhookRateLimit, getClient, invokeAppointmentRpc, jsonResponse,
  normalizeAppointmentDateTime, normalizeAppointmentPhone, normalizePatientName, normalizePlatformCallId,
  createVoiceIdempotencyKey, rpcFailure,
} from "./_shared/appointment.ts";

interface RescheduleBody {
  doctor_name?: string; patient_name?: string; phone_number?: string;
  phone_region?: string;
  existing_appointment_datetime?: string; appointment_datetime?: string;
  idempotency_key?: string; platform_call_id?: string; source?: string;
}

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;
  let body: RescheduleBody;
  try { body = await req.json(); } catch {
    return jsonResponse(rpcFailure("reschedule", "I didn't receive a valid request. Please try again."), 400);
  }
  const patientName = normalizePatientName(body.patient_name);
  const phone = normalizeAppointmentPhone(body.phone_number, body.phone_region);
  const doctorName = body.doctor_name?.trim();
  const oldTime = normalizeAppointmentDateTime(body.existing_appointment_datetime);
  const newTime = normalizeAppointmentDateTime(body.appointment_datetime);
  if (!doctorName || !patientName || !oldTime.ok || !newTime.ok) {
    return jsonResponse(rpcFailure("reschedule", "Please confirm the patient's name, doctor, phone number, existing appointment, and new 15-minute appointment time."), 400);
  }
  if (!phone.ok) return jsonResponse(appointmentPhoneFailure("reschedule", phone.reason), 400);
  const platformCallId = normalizePlatformCallId(body.platform_call_id) ?? normalizePlatformCallId(req.headers.get("x-call-id"));
  const idempotencyKey = await createVoiceIdempotencyKey("reschedule", [patientName, phone.e164, doctorName.trim().toLowerCase(), oldTime.timestamptz, newTime.timestamptz]);
  try {
    const result = await invokeAppointmentRpc(getClient(), "reschedule_appointment_v2", {
      p_patient_name: patientName, p_phone_e164: phone.e164, p_doctor_name: doctorName,
      p_existing_appointment_time: oldTime.timestamptz, p_new_appointment_time: newTime.timestamptz,
      p_idempotency_key: idempotencyKey,
      p_platform_call_id: platformCallId, p_source: "ai_agent", p_booking_window_days: 7,
    });
    return jsonResponse({ ...result, reschedule_success: result.success });
  } catch (error) {
    console.error("reschedule-appointment error", error);
    return jsonResponse(rpcFailure("reschedule", "Sorry, we could not reschedule that appointment. Please try again."), 500);
  }
});
