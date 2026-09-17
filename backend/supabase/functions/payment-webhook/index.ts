// Supabase Edge Function: payment gateway webhook (Razorpay/Stripe).
//
// This is the ONLY place a payment is ever marked "succeeded". The client
// never self-reports payment success — the gateway calls this endpoint
// server-to-server, we verify its signature, then update Postgres using the
// service role key (which bypasses RLS, since this is a trusted server context).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { mapGatewayStatus, verifySignature, walletDebitMinorUnits } from "./logic.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const webhookSecret = Deno.env.get("PAYMENT_GATEWAY_WEBHOOK_SECRET")!;

const supabase = createClient(supabaseUrl, serviceRoleKey);

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-gateway-signature");

  if (!verifySignature(rawBody, signature, webhookSecret)) {
    return new Response("Invalid signature", { status: 401 });
  }

  const event = JSON.parse(rawBody);
  const gatewayReference: string | undefined = event.payment_id ?? event.id;
  const status: string = event.status; // "captured" | "failed" | "refunded"

  if (!gatewayReference) {
    return new Response("Missing payment reference", { status: 400 });
  }

  const mappedStatus = mapGatewayStatus(status);

  const { data: updatedPayments, error } = await supabase
    .from("payments")
    .update({ status: mappedStatus })
    .eq("gateway_reference", gatewayReference)
    .select("id, visit_id, quote_id");

  if (error) {
    console.error("Failed to update payment status", error);
    return new Response("Internal error", { status: 500 });
  }

  const payment = updatedPayments?.[0];

  // If a subscription payment succeeded, extend its renewal date.
  if (mappedStatus === "succeeded" && event.subscription_id) {
    const nextRenewal = new Date();
    nextRenewal.setMonth(nextRenewal.getMonth() + 1);
    await supabase
      .from("subscriptions")
      .update({ status: "active", renewal_date: nextRenewal.toISOString() })
      .eq("id", event.subscription_id);
  }

  // E6/G6: a succeeded *visit* charge is the payment side of the booking
  // pipeline finishing — this is the one place visits.payment_id/status
  // are ever written from (the client's VisitRepository.attachPayment only
  // re-reads the row this already wrote). If the signed quote that
  // authorized this order applied a wallet credit (PricingEngine's "Wallet
  // credit" line item), debit the customer's wallet_ledger for real here —
  // the append-only ledger has no client-insert policy at all (see
  // 0026_wallet_ledger.sql), so this service-role write is the only place
  // that debit can legitimately happen.
  if (mappedStatus === "succeeded" && payment?.visit_id) {
    const { error: visitError } = await supabase
      .from("visits")
      .update({ payment_id: payment.id, status: "confirmed" })
      .eq("id", payment.visit_id)
      .eq("status", "requested"); // never regress a status that moved on already
    if (visitError) {
      console.error("Failed to confirm visit for payment", visitError);
    }

    if (payment.quote_id) {
      const { data: quoteRows } = await supabase
        .from("quotes")
        .select("breakdown, cart_id")
        .eq("id", payment.quote_id)
        .limit(1);
      const quote = quoteRows?.[0];
      const debit = walletDebitMinorUnits(quote?.breakdown?.lineItems);
      if (quote?.cart_id && debit !== null) {
        const { data: cartRows } = await supabase
          .from("carts").select("user_id").eq("id", quote.cart_id).limit(1);
        const userId = cartRows?.[0]?.user_id;
        if (userId) {
          const { error: ledgerError } = await supabase.from("wallet_ledger").insert({
            user_id: userId,
            amount_minor_units: debit, // always negative — see walletDebitMinorUnits
            reason: "visit_checkout_wallet_applied",
            related_visit_id: payment.visit_id,
          });
          if (ledgerError) console.error("Failed to debit wallet for checkout", ledgerError);
        }
      }
    }
  }

  return new Response("ok", { status: 200 });
});
