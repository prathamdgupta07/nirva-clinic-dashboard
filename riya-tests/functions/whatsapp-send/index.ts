// whatsapp-send
// Sends queued WhatsApp appointment messages through Meta's WhatsApp Cloud API.
//
// The database queues messages (see supabase/08_whatsapp.sql) and calls this
// function right after a booking change, and again every minute for retries.
// The caller needs no secret: this function only sends what the database has
// already queued, so calling it from outside cannot create or change messages.
//
// Secrets (set with `supabase secrets set`):
//   WHATSAPP_TOKEN            Meta access token (System User token for production)
//   WHATSAPP_PHONE_NUMBER_ID  "Phone number ID" from Meta > WhatsApp > API Setup
//   WHATSAPP_GRAPH_VERSION    optional, default v24.0
import { createClient } from "jsr:@supabase/supabase-js@2.118.0";

type Queued = {
  id: string;
  kind: string;
  to_e164: string;
  template_name: string;
  template_language: string;
  params: string[];
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// Meta rejects empty or very long template values, and newlines/tabs or
// more than 4 spaces in a row inside a value.
function clean(value: unknown): string {
  const text = String(value ?? "").replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim();
  return (text || "-").slice(0, 200);
}

async function sendOne(m: Queued, token: string, phoneNumberId: string, version: string) {
  const res = await fetch(`https://graph.facebook.com/${version}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to: m.to_e164.replace(/^\+/, ""),
      type: "template",
      template: {
        name: m.template_name,
        language: { code: m.template_language },
        components: [{
          type: "body",
          parameters: (m.params || []).map((p) => ({ type: "text", text: clean(p) })),
        }],
      },
    }),
    signal: AbortSignal.timeout(15000),
  });
  // deno-lint-ignore no-explicit-any
  const data: any = await res.json().catch(() => ({}));
  if (res.ok && data?.messages?.[0]?.id) {
    return { ok: true, id: String(data.messages[0].id), error: null, permanent: false };
  }
  const err = data?.error;
  const error = err
    ? `HTTP ${res.status} code ${err.code ?? "?"}: ${err.error_data?.details ?? err.message ?? "unknown"}`
    : `HTTP ${res.status}`;
  // Auth (401/403), rate limit (429) and Meta outages (5xx) are worth retrying.
  // Other 4xx (bad number, template not approved, bad values) will not fix themselves.
  const permanent = res.status >= 400 && res.status < 500 && ![401, 403, 429].includes(res.status);
  return { ok: false, id: null, error, permanent };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = Deno.env.get("WHATSAPP_TOKEN");
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  const version = Deno.env.get("WHATSAPP_GRAPH_VERSION") || "v24.0";
  if (!token || !phoneNumberId) {
    console.error("whatsapp-send: WHATSAPP_TOKEN or WHATSAPP_PHONE_NUMBER_ID is not set");
    return json({ error: "not configured" }, 503);
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await db.rpc("whatsapp_claim_batch", { p_limit: 20 });
  if (error) {
    console.error("whatsapp-send: claim failed", error.message);
    return json({ error: "claim failed" }, 500);
  }

  const batch = (data || []) as Queued[];
  let sent = 0, failed = 0;
  for (const m of batch) {
    let r: { ok: boolean; id: string | null; error: string | null; permanent: boolean };
    try {
      r = await sendOne(m, token, phoneNumberId, version);
    } catch (e) {
      r = { ok: false, id: null, error: `network: ${(e as Error).message}`, permanent: false };
    }
    if (r.ok) sent++;
    else {
      failed++;
      console.warn(`whatsapp-send: ${m.kind} ${m.id} failed: ${r.error}`);
    }
    const { error: markError } = await db.rpc("whatsapp_mark_result", {
      p_id: m.id, p_ok: r.ok, p_meta_message_id: r.id, p_error: r.error, p_permanent: r.permanent,
    });
    if (markError) console.error("whatsapp-send: mark failed", m.id, markError.message);
  }
  return json({ claimed: batch.length, sent, failed });
});
