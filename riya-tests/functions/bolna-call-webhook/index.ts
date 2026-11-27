// bolna-call-webhook (Riya Bolna test project only)
// Bolna POSTs the execution object at each status change (queued, ringing,
// in-progress, call-disconnected, completed, failed...). We upsert one row
// per execution id so later updates overwrite earlier ones.
// Auth: x-webhook-secret header (Bolna "Add headers") or ?key= query param,
// both checked against BOLNA_WEBHOOK_SECRET. Bolna does not sign webhooks.
import { createClient } from "jsr:@supabase/supabase-js@2.118.0";

// deno-lint-ignore no-explicit-any
type Any = Record<string, any>;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function num(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function text(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") return value.trim() || null;
  return JSON.stringify(value);
}

function e164(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const compact = value.trim().replace(/[\s().-]/g, "");
  if (/^\+[1-9][0-9]{6,14}$/.test(compact)) return compact;
  if (/^[0-9]{10}$/.test(compact)) return `+91${compact}`;
  if (/^91[0-9]{10}$/.test(compact)) return `+${compact}`;
  return compact || null;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const secret = Deno.env.get("BOLNA_WEBHOOK_SECRET");
  const provided = req.headers.get("x-webhook-secret") || new URL(req.url).searchParams.get("key") || "";
  if (!secret || !provided || !constantTimeEqual(provided, secret)) return json({ ok: false, error: "unauthorized" }, 401);

  let body: Any;
  try { body = await req.json(); } catch { return json({ ok: false, error: "invalid_json" }, 400); }
  const executionId = text(body.id ?? body.execution_id);
  if (!executionId) return json({ ok: false, error: "missing_execution_id" }, 400);

  const telephony: Any = body.telephony_data || {};
  const callType = text(telephony.call_type ?? body.call_type);
  // Inbound: the caller is from_number. Outbound: the patient is to_number.
  const caller = callType === "outbound" ? (telephony.to_number ?? body.user_number) : (telephony.from_number ?? body.user_number);
  const extracted = body.extracted_data ?? null;
  const status = text(body.status);
  const outcomeFromAgent = extracted && typeof extracted === "object" ? text((extracted as Any).call_outcome) : null;

  const row: Any = {
    call_id: executionId,
    platform: "bolna",
    phone_number: e164(caller),
    to_number: text(callType === "outbound" ? telephony.from_number : telephony.to_number),
    call_type: callType,
    status,
    termination_reason: text(telephony.hangup_reason ?? body.termination_reason),
    hangup_by: text(telephony.hangup_by ?? body.hangup_by),
    outcome: outcomeFromAgent || status,
    duration_seconds: (() => { const n = num(body.conversation_duration ?? telephony.duration); return n === null ? null : Math.round(n); })(),
    transcript: text(body.transcript),
    summary: text(body.summary),
    recording_url: text(telephony.recording_url ?? body.recording_url),
    total_cost: num(body.total_cost),
    cost_breakdown: body.cost_breakdown ?? null,
    extracted_data: extracted,
    started_at: text(body.initiated_at ?? body.created_at),
    updated_at: new Date().toISOString(),
    raw_payload: body,
  };

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return json({ ok: false, error: "server_config" }, 500);
  const db = createClient(url, key);

  try {
    if (row.phone_number) {
      const { data: patient } = await db.from("patients").select("id, name").eq("phone_e164", row.phone_number).limit(1);
      if (patient && patient[0]) { row.patient_id = patient[0].id; row.caller_name = patient[0].name; }
    }
    const { error } = await db.from("calls").upsert(row, { onConflict: "call_id" });
    if (error) throw error;
    return json({ ok: true });
  } catch (error) {
    console.error("bolna-call-webhook failed", error);
    // 500 lets Bolna retry; the upsert keeps retries idempotent.
    return json({ ok: false, error: "write_failed" }, 500);
  }
});
