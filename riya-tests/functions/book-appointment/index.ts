import {
  appointmentPhoneFailure, checkAuth, enforceWebhookRateLimit, getClient, invokeAppointmentRpc, jsonResponse,
  normalizeAppointmentDateTime, normalizeAppointmentPhone, normalizePatientName, normalizePlatformCallId,
  createVoiceIdempotencyKey, rpcFailure,
} from "./_shared/appointment.ts";

interface BookAppointmentBody {
  doctor_name?: string;
  patient_name?: string;
  /** Deprecated compatibility alias. New Voice AI tools must send patient_name. */
  caller_name?: string;
  phone_number?: string;
  phone_region?: string;
  appointment_datetime?: string;
  idempotency_key?: string;
  platform_call_id?: string;
  source?: string;
}

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;
  let body: BookAppointmentBody;
  try { body = await req.json(); } catch {
    return jsonResponse(rpcFailure("booking", "I didn't receive a valid request. Please try again."), 400);
  }
  const patientName = normalizePatientName(body.patient_name ?? body.caller_name);
  const phone = normalizeAppointmentPhone(body.phone_number, body.phone_region);
  const doctorName = body.doctor_name?.trim();
  const appointment = normalizeAppointmentDateTime(body.appointment_datetime);
  if (!doctorName || !patientName || !appointment.ok) {
    return jsonResponse(rpcFailure("booking", "Please confirm the patient's name, doctor, phone number, and a 15-minute appointment time."), 400);
  }
  if (!phone.ok) return jsonResponse(appointmentPhoneFailure("booking", phone.reason), 400);
  if (phone.e164.startsWith("+91") && phone.e164.length !== 13) {
    return jsonResponse({
      ...rpcFailure("booking", "Please confirm all ten digits after the +91 country code before booking."),
      error_code: "invalid_phone_number",
    }, 400);
  }
  const platformCallId = normalizePlatformCallId(body.platform_call_id) ?? normalizePlatformCallId(req.headers.get("x-call-id"));
  // A provider retry must carry either its stable call/delivery id or a UUID
  // idempotency key. Never generate an id server-side: that would convert a
  // retry into a second booking.
  const idempotencyKey = await createVoiceIdempotencyKey("book", [patientName, phone.e164, doctorName.trim().toLowerCase(), appointment.timestamptz]);
  try {
    const result = await invokeAppointmentRpc(getClient(), "book_appointment_v2", {
      p_patient_name: patientName,
      p_phone_e164: phone.e164,
      p_doctor_name: doctorName,
      p_appointment_time: appointment.timestamptz,
      p_idempotency_key: idempotencyKey,
      p_platform_call_id: platformCallId,
      p_source: "ai_agent",
      p_booking_window_days: 7,
    });
    return jsonResponse({ ...result, booking_success: result.success });
  } catch (error) {
    console.error("book-appointment error", error);
    return jsonResponse(rpcFailure("booking", "Sorry, we could not save that appointment. Please try again."), 500);
  }
});
