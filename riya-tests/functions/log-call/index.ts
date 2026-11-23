// log-call
// Edesy "Vani" post-call webhook. Confirmed real payload shape from the
// Edesy agent editor's "View Example Payload" panel (Integrations > Webhook):
// {
//   "event": "call.ended",
//   "timestamp": "...",
//   "call": { "id": "...", "callSid": "...", "direction": "inbound",
//              "from": "+91...", "to": "+91...", "duration": 180, "turnCount": 12 },
//   "agent": { "id": 82, "name": "..." },
//   "outcome": { "status": "completed", "disposition": "SUCCESS", ... }
// }
// Inserts one row into `calls`. Never blocks Edesy's call flow on failure.
import { checkAuth, enforceWebhookRateLimit, getClient, jsonResponse } from "./util.ts";

// deno-lint-ignore no-explicit-any
type AnyBody = Record<string, any>;

Deno.serve(async (req: Request) => {
  const authFail = checkAuth(req);
  if (authFail) return authFail;
  const rateLimitFail = await enforceWebhookRateLimit(req);
  if (rateLimitFail) return rateLimitFail;

  let body: AnyBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ resultText: "No call data received." });
  }

  const call: AnyBody = body.call || {};
  const outcomeObj: AnyBody = body.outcome || {};

  // Prefer the confirmed nested shape; keep a few flat-body fallbacks in case
  // Edesy ever sends a different event type with a flatter payload.
  const callId: string | null =
    call.id || call.callSid || body.call_id || body.callId || null;

  // A delivery without its provider event id cannot be made idempotent. Do
  // not write an untraceable duplicate into the operational call history.
  if (!callId || typeof callId !== "string" || !callId.trim()) {
    return jsonResponse({ resultText: "Call log was not recorded because the delivery did not include a call id." }, 400);
  }
  const phoneNumber: string | null =
    call.from || body.phone_number || body.caller_phone || body.from || null;
  const callerName: string | null =
    body.caller_name || body.customer_name || null;
  const durationSeconds: number | null = (() => {
    const v = call.duration ?? body.duration_seconds ?? body.call_duration ?? null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  })();
  const outcome: string | null =
    outcomeObj.status || outcomeObj.disposition || body.outcome || body.call_disposition || null;

  const client = getClient();

  try {
    const { data: existingCall, error: existingCallError } = await client
      .from("calls")
      .select("id")
      .eq("call_id", callId)
      .limit(1);
    if (existingCallError) throw existingCallError;
    if (existingCall && existingCall.length > 0) {
      return jsonResponse({ resultText: "Call log already recorded." });
    }

    // Best-effort link to an existing patient by phone (not required).
    let patientId: string | null = null;
    if (phoneNumber) {
      const { data: patientRows } = await client
        .from("patients")
        .select("id")
        .eq("phone", phoneNumber)
        .limit(1);
      patientId = (patientRows && patientRows[0]?.id) || null;
    }

    const { error: insertErr } = await client.from("calls").insert({
      call_id: callId,
      patient_id: patientId,
      phone_number: phoneNumber,
      outcome: outcome,
      duration_seconds: durationSeconds,
      caller_name: callerName,
    });
    // The unique database constraint also handles two deliveries arriving at
    // the same time. Treat the losing duplicate as a successful no-op.
    if (insertErr && insertErr.code !== "23505") throw insertErr;

    return jsonResponse({ resultText: insertErr ? "Call log already recorded." : "Call log recorded." });
  } catch (err) {
    console.error("log-call error:", err);
    // Never block Edesy's call flow on a logging failure.
    return jsonResponse({ resultText: "Call log could not be saved." }, 200);
  }
});
