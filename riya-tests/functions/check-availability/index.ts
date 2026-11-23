// check-availability
// Ports the CFS1-CFS4 + CFS-Exact/CFS-Prev/CFS-Next branches of
// "Sarvam Call Handler (Production)" (zsxKazR8Rn0QOQl8).
import {
  DateTime,
  checkAuth,
  computeSlots,
  dateLabel,
  enforceWebhookRateLimit,
  fmtTime12,
  getClient,
  isOnLeave,
  isWorkingDay,
  jsonResponse,
  resolveDoctorExact,
} from "./util.ts";

interface CheckAvailabilityBody {
  doctor_name: string;
  date?: string;
  time?: string;
  search_mode?: "exact" | "next";
  find_next?: boolean;
  booking_window_days?: number;
}

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;

  let body: CheckAvailabilityBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ resultText: "I didn't receive a valid request - could you try again?" });
  }

  const doctorName = (body.doctor_name || "").toString();
  if (!doctorName.trim()) {
    return jsonResponse({ resultText: "Which doctor would you like to check availability for?" });
  }

  const hasValidDate = /^\d{4}-\d{2}-\d{2}$/.test((body.date || "").toString().trim());
  const rawDateInput = hasValidDate ? body.date!.toString().trim() : "";
  const requestedTime = /^\d{2}:\d{2}$/.test((body.time || "").toString().trim())
    ? body.time!.toString().trim()
    : "";
  const bookingWindowDays = Number(body.booking_window_days) || 7;

  // Do not silently turn a malformed exact-date request into a next-slot
  // search. The agent must explicitly ask for the next available appointment.
  const findNext = body.search_mode === "next" || String(body.find_next).toLowerCase() === "true";
  if (!hasValidDate && !findNext) {
    return jsonResponse({ success: false, error_code: "invalid_date", resultText: "Please provide the exact appointment date in YYYY-MM-DD format, or explicitly ask for the next available appointment." }, 400);
  }

  const client = getClient();

  try {
    const doctor = await resolveDoctorExact(client, doctorName);
    if (!doctor || doctor.active === false) {
      return jsonResponse({
        resultText: `I don't have a doctor named ${doctorName} on file.`,
      });
    }

    const docStart = doctor.start_time.toString().substring(0, 5);
    const docEnd = doctor.end_time.toString().substring(0, 5);
    const docDays = (doctor.working_days || "")
      .toString()
      .split(",")
      .map((x) => Number(x.trim()));
    const docCanonicalName = doctor.name;

    const { data: leaveData, error: leaveErr } = await client
      .from("doctor_leave")
      .select("*")
      .eq("doctor_id", doctor.id);
    if (leaveErr) throw leaveErr;
    const leaveRanges = (leaveData || []).map(
      (r: { leave_start_date: string; leave_end_date: string }) => ({
        start: r.leave_start_date,
        end: r.leave_end_date,
      }),
    );


    const { data: bookingData, error: bookingErr } = await client
      .from("bookings")
      .select("appointment_time")
      .eq("doctor_id", doctor.id)
      .eq("status", "confirmed");
    if (bookingErr) throw bookingErr;
    const busyRanges = (bookingData || []).map((r: { appointment_time: string }) => ({
      start: r.appointment_time,
      end: DateTime.fromISO(r.appointment_time).plus({ minutes: 15 }).toISO()!,
    }));

    const todayStr = DateTime.now().setZone("Asia/Kolkata").toFormat("yyyy-MM-dd");
    const maxDateStr = DateTime.now()
      .setZone("Asia/Kolkata")
      .plus({ days: bookingWindowDays })
      .toFormat("yyyy-MM-dd");
    const anchorDateStr = hasValidDate ? rawDateInput : todayStr;

    function buildSuccessMsg(dateStr: string, slots: string[]): string {
      const d = DateTime.fromISO(dateStr, { zone: "Asia/Kolkata" });
      const dateText = dateLabel(d);
      if (requestedTime) {
        const available = slots.includes(requestedTime);
        if (available) {
          return `Yes, ${docCanonicalName} is available on ${dateText} at ${fmtTime12(requestedTime)}.`;
        }
        const s = slots.map(fmtTime12);
        const shown = s.slice(0, 3);
        
        return `No, ${docCanonicalName} is not available at ${fmtTime12(
          requestedTime,
        )} on ${dateText}. Available times are - Date: ${dateText}. Time: ${shown.join(", ")}.`;
      }
      const s = slots.map(fmtTime12);
      const shown = s.slice(0, 3);
      
      return `${docCanonicalName} is available. Date: ${dateText}. Time: ${shown.join(", ")}.`;
    }

    function buildSuccessPayload(dateStr: string, slots: string[]) {
      return {
        success: true,
        doctor_name: docCanonicalName,
        date: dateStr,
        requested_time: requestedTime || null,
        requested_slot_available: requestedTime ? slots.includes(requestedTime) : null,
        available_slots: slots.slice(0, 3),
        next_available_slot: slots[0] || null,
        resultText: buildSuccessMsg(dateStr, slots),
      };
    }

    // Exact mode
    if (!findNext) {
      if (rawDateInput < todayStr) {
        return jsonResponse({
          resultText: "That date has already passed. Please choose today or a future date.",
        });
      }
      if (rawDateInput > maxDateStr) {
        return jsonResponse({
          resultText: `That date is outside the booking window - appointments can only be made up to ${bookingWindowDays} days ahead.`,
        });
      }
      if (isOnLeave(rawDateInput, leaveRanges)) {
        return jsonResponse({ success: false, error_code: "no_availability", resultText: `${doctorName} is on leave that day.` });
      }
      if (!isWorkingDay(rawDateInput, docDays)) {
        return jsonResponse({ success: false, error_code: "no_availability", resultText: `${doctorName} does not see patients on that day.` });
      }
      const slots = computeSlots(rawDateInput, docStart, docEnd, busyRanges);
      if (requestedTime && !slots.includes(requestedTime)) {
        const minutes = (time: string) => Number(time.slice(0, 2)) * 60 + Number(time.slice(3));
        const requestedMinutes = minutes(requestedTime);
        slots.sort((a, b) => Math.abs(minutes(a) - requestedMinutes) - Math.abs(minutes(b) - requestedMinutes));
      }
      if (slots.length > 0) {
        return jsonResponse(buildSuccessPayload(rawDateInput, slots));
      }
      const d = DateTime.fromISO(rawDateInput, { zone: "Asia/Kolkata" });
      return jsonResponse({
        success: false,
        error_code: "no_availability",
        resultText: `No open slots left with ${doctorName} on ${dateLabel(d)}.`,
      });
    }

    // Next mode: walk forward only; previous availability is intentionally not offered.
    const direction = 1;
    const candidates: string[] = [];
    const firstOffset = 0;
    for (let i = firstOffset; i < firstOffset + 7; i++) {
      const cand = DateTime.fromISO(anchorDateStr, { zone: "Asia/Kolkata" }).plus({
        days: direction * i,
      });
      if (findNext && cand > DateTime.fromISO(maxDateStr, { zone: "Asia/Kolkata" })) continue;
      candidates.push(cand.toFormat("yyyy-MM-dd"));
    }

    for (const cand of candidates) {
      const valid = isWorkingDay(cand, docDays) && !isOnLeave(cand, leaveRanges);
      if (!valid) continue;
      const slots = computeSlots(cand, docStart, docEnd, busyRanges);
      if (slots.length > 0) {
        return jsonResponse(buildSuccessPayload(cand, slots));
      }
    }

    return jsonResponse({
      success: false,
      error_code: "no_availability",
      resultText: `No availability found for ${doctorName} within the next ${bookingWindowDays} days.`,
    });
  } catch (err) {
    console.error("check-availability error:", err);
    return jsonResponse({
      resultText: "I'm having trouble checking availability right now - could you try again in a moment?",
    });
  }
});
