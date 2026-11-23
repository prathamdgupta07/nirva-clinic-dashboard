// sarvam-call-webhook (Riya Sarvam test project only)
// Sarvam POSTs once when an inbound call ends (deployment webhook_config).
// Auth, either of:
//   1. Signed webhook (webhook_id style): Sarvam-Signature header, HMAC-SHA256
//      of "<timestamp>.<raw body>" with SARVAM_CALL_WEBHOOK_SIGNING_SECRET,
//      rejected when older than 5 minutes.
//   2. Fallback for unsigned URL-style webhooks: ?key= or x-webhook-secret
//      equal to SARVAM_WEBHOOK_SECRET.
// Upserts one row per interaction_id. The raw body is always kept.
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

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Accepts "t=<ts>,v1=<hex>" or a bare hex signature with a separate timestamp header. */
async function signatureValid(req: Request, raw: string, secret: string): Promise<boolean> {
  const header = req.headers.get("sarvam-signature") || "";
  if (!header) return false;
  const parts: Record<string, string> = {};
  for (const piece of header.split(",")) {
    const [k, ...rest] = piece.trim().split("=");
    if (k && rest.length) parts[k.trim()] = rest.join("=").trim();
  }
  const timestamp = parts.t || parts.timestamp || req.headers.get("sarvam-timestamp") || req.headers.get("x-sarvam-timestamp") || "";
  const provided = (parts.v1 || parts.signature || (Object.keys(parts).length ? "" : header)).toLowerCase().replace(/^sha256=/, "");
  if (!timestamp || !provided) return false;
  const tsNum = Number(timestamp);
  const tsMs = tsNum > 1e12 ? tsNum : tsNum * 1000;
  if (!Number.isFinite(tsMs) || Math.abs(Date.now() - tsMs) > 5 * 60 * 1000) return false;
  const expected = await hmacHex(secret, `${timestamp}.${raw}`);
  return constantTimeEqual(provided, expected);
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
  const raw = await req.text();

  const signingSecret = Deno.env.get("SARVAM_CALL_WEBHOOK_SIGNING_SECRET");
  const sharedSecret = Deno.env.get("SARVAM_WEBHOOK_SECRET");
  const provided = req.headers.get("x-webhook-secret") || new URL(req.url).searchParams.get("key") || "";
  const signedOk = signingSecret ? await signatureValid(req, raw, signingSecret) : false;
  const sharedOk = !!sharedSecret && !!provided && constantTimeEqual(provided, sharedSecret);
  if (!signedOk && !sharedOk) return json({ ok: false, error: "unauthorized" }, 401);

  let body: Any;
  try { body = JSON.parse(raw); } catch { return json({ ok: false, error: "invalid_json" }, 400); }
  const data: Any = body.data && typeof body.data === "object" ? body.data : body;
  const interactionId = text(data.interaction_id ?? data.id);
  if (!interactionId) return json({ ok: false, error: "missing_interaction_id" }, 400);

  const outputVars: Any | null = data.output_agent_variables ?? null;
  const finalVars: Any | null = data.final_agent_variables ?? null;
  const callOutcome = text(outputVars?.call_outcome ?? finalVars?.call_outcome);
  const callerName = text(outputVars?.patient_name ?? finalVars?.patient_name);

  const row: Any = {
    call_id: interactionId,
    platform: "sarvam",
    phone_number: e164(data.user_phone_number ?? data.user_identifier),
    agent_phone_number: text(data.agent_phone_number),
    deployment_id: text(data.deployment_id),
    app_version: num(data.app_version),
    started_at: text(data.start_datetime),
    ended_at: text(data.end_datetime),
    duration_seconds: (() => { const n = num(data.duration); return n === null ? null : Math.round(n); })(),
    outcome: callOutcome,
    caller_name: callerName,
    transcript: data.interaction_transcript ?? null,
    extracted_data: outputVars,
    final_variables: finalVars,
    recording_url: text(data.recording_url),
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
      if (patient && patient[0]) { row.patient_id = patient[0].id; row.caller_name = row.caller_name || patient[0].name; }
    }
    const { error } = await db.from("calls").upsert(row, { onConflict: "call_id" });
    if (error) throw error;
    return json({ ok: true });
  } catch (error) {
    console.error("sarvam-call-webhook failed", error);
    return json({ ok: false, error: "write_failed" }, 500);
  }
});
