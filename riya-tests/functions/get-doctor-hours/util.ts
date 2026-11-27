// Shared helpers for Nirva / Riya Supabase Edge Functions.
// Ported faithfully from the live n8n workflows:
//   "Sarvam Call Handler (Production)" (zsxKazR8Rn0QOQl8)
//   "Book Appointment (Sarvam)" (8xHydTcAWmzsD2H5)
// Timezone rule and double-booking fix match the 2026-09-04 bug fixes.

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2.118.0";
import { DateTime } from "npm:luxon@3.5.0";

export { DateTime };

export function getClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return createClient(url, key);
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let different = 0;
  for (let index = 0; index < left.length; index += 1) different |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return different === 0;
}

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

export function checkAuth(req: Request): Response | null {
  if (!webhookSource(req)) {
    return jsonResponse({ resultText: "Unauthorized." }, 401);
  }
  return null;
}

export async function enforceWebhookRateLimit(req: Request): Promise<Response | null> {
  const source = webhookSource(req);
  if (!source) return jsonResponse({ resultText: "Unauthorized." }, 401);
  try {
    const { data, error } = await getClient().rpc("consume_webhook_rate_limit", { p_source: source, p_limit: 60 });
    if (error || data !== true) return jsonResponse({ resultText: "Please try again in a minute." }, 429);
  } catch (error) {
    console.error("webhook rate-limit check failed", error);
    return jsonResponse({ resultText: "Please try again shortly." }, 503);
  }
  return null;
}

export function normalizeDocName(s: string | null | undefined): string {
  return (s || "").toString().trim().toLowerCase().replace(/^dr\.?\s+/, "");
}

export function surnameOf(doctorName: string | null | undefined): string {
  const parts = (doctorName || "").toString().trim().split(" ");
  return parts[parts.length - 1] || "";
}

// "HH:mm" -> "11:00 am"
export function fmtTime12(t: string): string {
  return DateTime.fromFormat(t, "HH:mm").toFormat("h:mm a").toLowerCase();
}

// "HH:mm[:ss]" -> "10 AM" / "10:30 AM" (used by get-doctor-hours, matches
// Build Doctor Hours Response's own hand-rolled formatter, not fmtTime12)
export function fmtTimeGeneral(t: string): string {
  const [hStr, mStr] = t.split(":");
  const h = Number(hStr);
  const m = Number(mStr || 0);
  const hh = h % 12 || 12;
  const ap = h < 12 ? "AM" : "PM";
  return hh + (m ? ":" + String(m).padStart(2, "0") : "") + " " + ap;
}

export function ordinal(n: number): string {
  const sfx = ["th", "st", "nd", "rd"];
  const v = n % 100;
  return String(n) + (sfx[(v - 20) % 10] || sfx[v] || sfx[0]);
}

export function dateLabel(dt: InstanceType<typeof DateTime>): string {
  return ordinal(dt.day) + " " + dt.toFormat("MMMM");
}

export interface Range {
  start: string;
  end: string;
}

export function computeSlots(
  dateStr: string,
  docStart: string,
  docEnd: string,
  busyRanges: Range[],
): string[] {
  const [sh, sm] = docStart.split(":").map(Number);
  const [eh, em] = docEnd.split(":").map(Number);
  const start = DateTime.fromISO(dateStr, { zone: "Asia/Kolkata" }).set({
    hour: sh,
    minute: sm,
    second: 0,
    millisecond: 0,
  });
  const end = DateTime.fromISO(dateStr, { zone: "Asia/Kolkata" }).set({
    hour: eh,
    minute: em,
    second: 0,
    millisecond: 0,
  });
  const total = Math.max(0, Math.floor(end.diff(start, "minutes").minutes / 15));
  return Array.from({ length: total }, (_, i) => start.plus({ minutes: i * 15 }))
    .filter(
      (s) =>
        !(busyRanges || []).some(
          (b) =>
            DateTime.fromISO(b.start) < s.plus({ minutes: 15 }) &&
            DateTime.fromISO(b.end) > s,
        ),
    )
    .map((s) => s.toFormat("HH:mm"));
}

export function isOnLeave(rawDate: string, leaveRanges: Range[]): boolean {
  return leaveRanges.some(
    (r) =>
      DateTime.fromISO(String(r.start)).toFormat("yyyy-MM-dd") <= rawDate &&
      DateTime.fromISO(String(r.end)).toFormat("yyyy-MM-dd") >= rawDate,
  );
}

export function isWorkingDay(rawDate: string, docDays: number[]): boolean {
  return docDays.includes(
    DateTime.fromISO(rawDate, { zone: "Asia/Kolkata" }).weekday % 7,
  );
}

// Ports "Normalize Appointment DateTime" exactly: accepts a handful of
// human/ISO formats, and always returns a NAIVE "yyyy-MM-dd'T'HH:mm:ss"
// string (any incoming offset is discarded on purpose - the clock digits are
// what's kept, then later re-interpreted as Asia/Kolkata at insert time).
// This is the exact approach that fixed the 5.5h timezone bug in n8n.
const DATETIME_FORMATS = [
  "yyyy-MM-dd h:mm a",
  "yyyy-MM-dd HH:mm",
  "yyyy-MM-dd H:mm",
  "MMMM d, yyyy h:mm a",
  "MMMM d, yyyy 'at' h:mm a",
  "MMM d, yyyy h:mm a",
  "M/d/yyyy h:mm a",
  "yyyy/MM/dd HH:mm",
];

export function normalizeAppointmentDateTime(
  raw: unknown,
): { ok: true; iso: string } | { ok: false } {
  if (!raw || typeof raw !== "string") return { ok: false };
  const trimmed = raw.trim();
  if (
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?([+-]\d{2}:\d{2}|Z)?$/.test(trimmed)
  ) {
    const dt = DateTime.fromISO(trimmed);
    if (dt.isValid) return { ok: true, iso: dt.toFormat("yyyy-MM-dd'T'HH:mm:ss") };
  }
  for (const fmt of DATETIME_FORMATS) {
    const dt = DateTime.fromFormat(trimmed, fmt);
    if (dt.isValid) return { ok: true, iso: dt.toFormat("yyyy-MM-dd'T'HH:mm:ss") };
  }
  return { ok: false };
}

export interface DoctorRow {
  id: string;
  name: string;
  specialty?: string;
  active?: boolean;
  start_time: string;
  end_time: string;
  working_days: string;
}

// Ports "Resolve Doctor" (book/reschedule/cancel/save-callback): surname
// ilike, first match wins. NOTE: unlike check_availability / get_doctor_hours
// this does NOT require an exact full-name match - faithfully replicated,
// even though it's a looser check than the other two tools use.
export async function resolveDoctorBySurname(
  client: SupabaseClient,
  doctorName: string,
): Promise<DoctorRow | null> {
  const surname = surnameOf(doctorName);
  const { data, error } = await client
    .from("doctors")
    .select("*")
    .ilike("name", `%${surname}%`)
    .limit(1);
  if (error) throw error;
  return (data && data[0]) || null;
}

// Ports the exact-full-name-match step used by check_availability and
// get_doctor_hours (surname ilike first, then normalized full-name equality).
export async function resolveDoctorExact(
  client: SupabaseClient,
  doctorName: string,
): Promise<DoctorRow | null> {
  const surname = surnameOf(doctorName);
  const { data, error } = await client
    .from("doctors")
    .select("*")
    .ilike("name", `%${surname}%`);
  if (error) throw error;
  const rows = (data || []) as DoctorRow[];
  return (
    rows.find((r) => normalizeDocName(r.name) === normalizeDocName(doctorName)) ||
    null
  );
}

export interface AttemptBookingParams {
  toolCallId?: string | null;
  doctorNameInput: string;
  patientName: string;
  phone: string;
  appointmentTimeNaiveIso: string; // naive "yyyy-MM-dd'T'HH:mm:ss"
  bookingWindowDays?: number;
}

export interface AttemptBookingResult {
  status:
    | "success"
    | "duplicate"
    | "no_doctor"
    | "invalid_slot"
    | "conflict"
    | "error";
  resultText: string;
  bookingId?: string;
}

// Ports the "Book Appointment (Sarvam)" sub-workflow end to end, including
// the dedupe-by-tool_call_id check and the double-booking DB constraint
// (unique index bookings_no_double_book on (doctor_id, appointment_time)
// WHERE status='confirmed') -> conflict response on 23505.
export async function attemptBooking(
  client: SupabaseClient,
  params: AttemptBookingParams,
): Promise<AttemptBookingResult> {
  const {
    toolCallId,
    doctorNameInput,
    patientName,
    phone,
    appointmentTimeNaiveIso,
    bookingWindowDays,
  } = params;
  const windowDays = Number(bookingWindowDays) || 7;

  // 1. Dedupe by tool_call_id (only if caller supplied one)
  if (toolCallId) {
    const { data: dupRows, error: dupErr } = await client
      .from("bookings")
      .select("id, appointment_time")
      .eq("tool_call_id", toolCallId)
      .limit(1);
    if (dupErr) throw dupErr;
    if (dupRows && dupRows[0]) {
      return {
        status: "duplicate",
        resultText: `You already have that appointment booked for ${dupRows[0].appointment_time}.`,
      };
    }
  }

  // 2. Resolve doctor by surname (first match wins)
  const doctor = await resolveDoctorBySurname(client, doctorNameInput);
  if (!doctor) {
    return {
      status: "no_doctor",
      resultText: `I don't have a doctor named ${doctorNameInput} on file.`,
    };
  }

  // 3. Cross-check working hours by EXACT full-name match against all doctors
  //    (faithful port of "Validate: Get Doctor (Supabase)" + in-code find())
  const { data: allDoctors, error: allDocErr } = await client
    .from("doctors")
    .select("*");
  if (allDocErr) throw allDocErr;
  const whRow = ((allDoctors || []) as DoctorRow[]).find(
    (r) => normalizeDocName(r.name) === normalizeDocName(doctorNameInput),
  );

  const { data: leaveRows, error: leaveErr } = await client
    .from("doctor_leave")
    .select("*")
    .eq("doctor_id", doctor.id);
  if (leaveErr) throw leaveErr;

  const dt = DateTime.fromISO(appointmentTimeNaiveIso, { zone: "Asia/Kolkata" });
  const rawDate = dt.toFormat("yyyy-MM-dd");
  const reqTime = dt.toFormat("HH:mm");
  const maxDateStr = DateTime.now()
    .setZone("Asia/Kolkata")
    .plus({ days: windowDays })
    .toFormat("yyyy-MM-dd");

  let valid = true;
  let reason = "";

  if (rawDate > maxDateStr) {
    valid = false;
    reason = `That date is outside the booking window - appointments can only be made up to ${windowDays} days ahead.`;
  } else if (!whRow) {
    valid = false;
    reason = `I don't have working-hours information for ${doctorNameInput}.`;
  } else {
    const docStart = whRow.start_time.toString().substring(0, 5);
    const docEnd = whRow.end_time.toString().substring(0, 5);
    const docDays = (whRow.working_days || "")
      .toString()
      .split(",")
      .map((x) => Number(x.trim()));

    const leaveRanges: Range[] = (leaveRows || [])
      .filter((r: { doctor_id: string }) => r.doctor_id === doctor.id)
      .map((r: { leave_start_date: string; leave_end_date: string }) => ({
        start: r.leave_start_date,
        end: r.leave_end_date,
      }));

    if (isOnLeave(rawDate, leaveRanges)) {
      valid = false;
      reason = `${doctorNameInput} is on leave that day.`;
    } else if (!isWorkingDay(rawDate, docDays)) {
      valid = false;
      reason = `${doctorNameInput} does not see patients on that day.`;
    } else {
      const apptEnd = dt.plus({ minutes: 15 }).toFormat("HH:mm");
      if (reqTime < docStart || apptEnd > docEnd) {
        valid = false;
        reason = `${doctorNameInput}'s hours are ${fmtTime12(docStart)} to ${fmtTime12(
          docEnd,
        )} on that day, so ${fmtTime12(reqTime)} isn't available - would you like a different time?`;
      }
    }
  }

  if (!valid) {
    return { status: "invalid_slot", resultText: reason };
  }

  // 4. Resolve or create patient by phone
  const { data: patientRows, error: patErr } = await client
    .from("patients")
    .select("id")
    .eq("phone", phone)
    .limit(1);
  if (patErr) throw patErr;

  let patientId: string;
  if (patientRows && patientRows[0]) {
    patientId = patientRows[0].id;
  } else {
    const { data: newPatient, error: createErr } = await client
      .from("patients")
      .insert({ name: patientName, phone })
      .select("id")
      .single();
    if (createErr) throw createErr;
    patientId = newPatient.id;
  }

  // 5. Insert booking (Asia/Kolkata offset applied explicitly - the fix for
  //    the 5.5h timezone bug)
  const appointmentTimeIso = DateTime.fromISO(appointmentTimeNaiveIso, {
    zone: "Asia/Kolkata",
  }).toISO();

  const { data: booking, error: insertErr } = await client
    .from("bookings")
    .insert({
      patient_id: patientId,
      doctor_id: doctor.id,
      appointment_time: appointmentTimeIso,
      status: "confirmed",
      source: "ai_agent",
      tool_call_id: toolCallId ?? null,
    })
    .select("id")
    .single();

  if (insertErr) {
    if (insertErr.code === "23505") {
      return {
        status: "conflict",
        resultText: "That slot was just taken by someone else - want a different time?",
      };
    }
    throw insertErr;
  }

  return {
    status: "success",
    bookingId: booking.id,
    resultText: `Booked! ${doctorNameInput} on ${dt.toFormat("yyyy-MM-dd")} at ${dt.toFormat(
      "HH:mm",
    )}.`,
  };
}
