// Supabase Edge Function: G9 chargeback/dispute webhook (Razorpay/Stripe
// style). Mirrors payment-webhook's trusted-boundary exactly: the gateway
// calls this endpoint server-to-server with a signed payload when a
// cardholder disputes a charge, we verify the signature, then upsert
// Postgres using the service role key. The client never creates or edits a
// dispute row directly — payment_disputes has no insert/update policy for
// any client role at all.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createHmac, timingSafeEqual } from "node:crypto";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const webhookSecret = Deno.env.get("DISPUTE_WEBHOOK_SECRET")!;

const supabase = createClient(supabaseUrl, serviceRoleKey);

function verifySignature(rawBody: string, signatureHeader: string | null): boolean {
  if (!signatureHeader) return false;
  const expected = createHmac("sha256", webhookSecret).update(rawBody).digest("hex");
  const expectedBuf = Buffer.from(expected, "utf8");
  const givenBuf = Buffer.from(signatureHeader, "utf8");
  return expectedBuf.length === givenBuf.length && timingSafeEqual(expectedBuf, givenBuf);
}

const STATUS_MAP: Record<string, string> = {
  "dispute.created": "open",
  "dispute.needs_response": "needs_response",
  "dispute.won": "won",
  "dispute.lost": "lost",
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const rawBody = await req.text();
  const signature = req.headers.get("x-gateway-signature");
  if (!verifySignature(rawBody, signature)) {
    return new Response("Invalid signature", { status: 401 });
  }

  const event = JSON.parse(rawBody);
  const gatewayDisputeId: string | undefined = event.dispute_id ?? event.id;
  const gatewayPaymentReference: string | undefined = event.payment_id;
  const eventType: string | undefined = event.event ?? event.type;

  if (!gatewayDisputeId || !gatewayPaymentReference || !eventType) {
    return new Response("Missing dispute_id, payment_id, or event type", { status: 400 });
  }

  const mappedStatus = STATUS_MAP[eventType];
  if (!mappedStatus) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: `Unrecognized event type: ${eventType}` }), { status: 400 });
  }

  const { data: payment, error: paymentError } = await supabase
    .from("payments")
    .select("id, visit_id")
    .eq("gateway_reference", gatewayPaymentReference)
    .maybeSingle();

  if (paymentError || !payment || !payment.visit_id) {
    console.error("Dispute webhook: no matching payment/visit for", gatewayPaymentReference, paymentError);
    return new Response(JSON.stringify({ code: "VALIDATION", message: "No matching payment for this dispute." }), { status: 422 });
  }

  const now = new Date().toISOString();
  const isTerminal = mappedStatus === "won" || mappedStatus === "lost";

  // Upsert on gateway_dispute_id: the first webhook (dispute.created) inserts
  // the row; later lifecycle events (needs_response/won/lost) update the
  // same row rather than creating duplicates.
  const { error: upsertError } = await supabase
    .from("payment_disputes")
    .upsert(
      {
        payment_id: payment.id,
        visit_id: payment.visit_id,
        gateway_dispute_id: gatewayDisputeId,
        reason: event.reason ?? "unknown",
        amount_minor_units: event.amount_minor_units ?? 0,
        status: mappedStatus,
        resolved_at: isTerminal ? now : null,
        updated_at: now,
      },
      { onConflict: "gateway_dispute_id" },
    );

  if (upsertError) {
    console.error("Failed to upsert payment dispute", upsertError);
    return new Response("Internal error", { status: 500 });
  }

  return new Response("ok", { status: 200 });
});
