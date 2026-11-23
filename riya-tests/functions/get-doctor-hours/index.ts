// get-doctor-hours
// Ports "Get Doctor Hours (Supabase)" + "Build Doctor Hours Response" from
// "Sarvam Call Handler (Production)". Pure background-knowledge lookup -
// does NOT look at bookings, only doctors.start_time/end_time/working_days.
import { checkAuth, enforceWebhookRateLimit, fmtTimeGeneral, getClient, jsonResponse, resolveDoctorExact } from "./util.ts";

interface GetDoctorHoursBody {
  doctor_name: string;
}

const DAY_NAMES: Record<number, string> = {
  0: "Sunday",
  1: "Monday",
  2: "Tuesday",
  3: "Wednesday",
  4: "Thursday",
  5: "Friday",
  6: "Saturday",
};

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;

  let body: GetDoctorHoursBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ resultText: "I didn't receive a valid request - could you try again?" });
  }

  const doctorName = (body.doctor_name || "").toString();
  if (!doctorName.trim()) {
    return jsonResponse({ resultText: "Which doctor's hours would you like to know?" });
  }

  const client = getClient();

  try {
    const doctor = await resolveDoctorExact(client, doctorName);
    if (!doctor) {
      return jsonResponse({
        resultText: `I don't have a doctor named ${doctorName} on file.`,
      });
    }

    const days = (doctor.working_days || "")
      .toString()
      .split(",")
      .map((x) => Number(x.trim()))
      .sort((a, b) => a - b)
      .map((d) => DAY_NAMES[d]);
    const isMonFri = JSON.stringify(days) === JSON.stringify([
      "Monday",
      "Tuesday",
      "Wednesday",
      "Thursday",
      "Friday",
    ]);
    const daysText = isMonFri ? "Monday to Friday" : days.join(", ");

    const resultText = `${doctor.name} sits from ${fmtTimeGeneral(
      doctor.start_time,
    )} to ${fmtTimeGeneral(doctor.end_time)}, ${daysText}.`;

    return jsonResponse({ resultText });
  } catch (err) {
    console.error("get-doctor-hours error:", err);
    return jsonResponse({
      resultText: "I'm having trouble checking that right now - could you try again in a moment?",
    });
  }
});
