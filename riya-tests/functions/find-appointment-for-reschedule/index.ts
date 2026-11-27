import { checkAuth, enforceWebhookRateLimit, getClient, jsonResponse, normalizeAppointmentDateTime, normalizeAppointmentPhone } from "./_shared/appointment.ts";

const doctorKey = (name: string) => name.trim().replace(/^dr\.?\s+/i, "").replace(/\s+/g, " ").toLowerCase();

Deno.serve(async (req: Request) => {
  const authFailure = checkAuth(req);
  if (authFailure) return authFailure;
  if (req.method !== "POST") return jsonResponse({ success: false, error_code: "METHOD_NOT_ALLOWED" }, 405);
  const rateFailure = await enforceWebhookRateLimit(req);
  if (rateFailure) return rateFailure;

  try {
    const body = await req.json().catch(() => null);
    const doctor = typeof body?.doctor_name === "string" ? doctorKey(body.doctor_name) : "";
    const phone = normalizeAppointmentPhone(body?.phone_number, body?.phone_region);
    const time = normalizeAppointmentDateTime(body?.existing_appointment_datetime);
    if (!doctor || !phone.ok || !time.ok) return jsonResponse({ success: false, error_code: "INVALID_LOOKUP_DETAILS" }, 400);

    const db = getClient();
    const { data: doctors, error: doctorsError } = await db.from("doctors").select("id,name").eq("active", true);
    if (doctorsError) throw doctorsError;
    const matches = doctors.filter((row) => doctorKey(row.name) === doctor);
    if (matches.length !== 1) return jsonResponse({ success: false, error_code: matches.length ? "AMBIGUOUS_MATCH" : "BOOKING_NOT_FOUND" });

    const { data: bookings, error: bookingsError } = await db.from("bookings")
      .select("patient_name_snapshot").eq("doctor_id", matches[0].id)
      .eq("phone_e164_snapshot", phone.e164).eq("appointment_time", time.timestamptz)
      .eq("status", "confirmed").limit(2);
    if (bookingsError) throw bookingsError;
    if (bookings.length !== 1 || !bookings[0].patient_name_snapshot) {
      return jsonResponse({ success: false, error_code: bookings.length > 1 ? "AMBIGUOUS_MATCH" : "BOOKING_NOT_FOUND" });
    }
    return jsonResponse({ success: true, patient_name: bookings[0].patient_name_snapshot, doctor_name: matches[0].name });
  } catch {
    console.error("find-appointment-for-reschedule failed");
    return jsonResponse({ success: false, error_code: "LOOKUP_FAILED" }, 500);
  }
});
