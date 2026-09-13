// Supabase Edge Function: G8 daily reconciliation — meant to be invoked by a
// cron trigger (`select cron.schedule(...)` calling this function's URL, or
// the Supabase Dashboard's Cron Jobs UI) once a day.
//
// There is no real payment gateway wired into this codebase yet (checkout is
// a mocked hosted-checkout URL — see PaymentRepository/MockRepositories) so
// this function cannot call a live settlement-report API. Instead it accepts
// the settlement report as its POST body, as if a gateway's daily settlement
// webhook or a manual ops CSV upload fed it: an array of gateway transaction
// records `{ id, amount_minor_units, status, settled_at }`.
//
// It compares that report against our own `payments` ledger and writes one
// `reconciliation_mismatches` row per discrepancy, using the service-role
// key — exactly the "server-only financial write" discipline used by
// issue-refund and payment-webhook. There is nothing for a client role to
// INSERT here directly even if it wanted to: reconciliation_mismatches has
// no insert policy for authenticated/anon at all.
//
// This is intentionally an ops/back-office job: no customer ever needs (or
// should see) a reconciliation mismatch, so there is no customer-facing
// domain/UI layer for G8 — only this function + its migration.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Shared secret the cron scheduler (or an ops uploader) presents instead of
// a user JWT — this function runs with no signed-in user at all.
const reconciliationSecret = Deno.env.get("RECONCILIATION_JOB_SECRET")!;

interface GatewayTransaction {
  id: string; // gateway_reference, matched against payments.gateway_reference
  amount_minor_units: number;
  status: string; // gateway's own status vocabulary, e.g. "settled" | "failed" | "pending"
  settled_at: string | null;
}

const admin = createClient(supabaseUrl, serviceRoleKey);

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== `Bearer ${reconciliationSecret}`) {
    return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });
  }

  const body = await req.json().catch(() => null);
  const settlementReport: GatewayTransaction[] = body?.settlement_report ?? [];
  if (!Array.isArray(settlementReport)) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: "settlement_report must be an array." }), { status: 400 });
  }

  // Window: the report is expected to cover "yesterday" (or whatever range
  // the caller chose) — we only pull payments that have a gateway_reference
  // at all, since a payment that never reached the gateway (e.g. still
  // pending on our side) isn't a reconciliation candidate yet.
  const { data: payments, error: paymentsError } = await admin
    .from("payments")
    .select("id, amount_minor_units, status, gateway_reference")
    .not("gateway_reference", "is", null);

  if (paymentsError) {
    console.error("Failed to load payments for reconciliation", paymentsError);
    return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not load ledger." }), { status: 500 });
  }

  const runId = crypto.randomUUID();
  const byReference = new Map(settlementReport.map((t) => [t.id, t]));
  const matchedGatewayIds = new Set<string>();
  const mismatches: Record<string, unknown>[] = [];

  for (const payment of payments ?? []) {
    const ref = payment.gateway_reference as string;
    const gatewayTxn = byReference.get(ref);

    if (payment.status !== "succeeded" && payment.status !== "refunded") {
      // Not yet expected to have settled on our side either; skip.
      continue;
    }

    if (!gatewayTxn) {
      mismatches.push({
        run_id: runId,
        payment_id: payment.id,
        gateway_transaction_id: ref,
        kind: "missing_in_gateway",
        ledger_amount_minor_units: payment.amount_minor_units,
        details: "Payment marked settled locally but no matching record in the gateway settlement report.",
      });
      continue;
    }

    matchedGatewayIds.add(ref);

    if (gatewayTxn.status !== "settled" && gatewayTxn.status !== "captured") {
      mismatches.push({
        run_id: runId,
        payment_id: payment.id,
        gateway_transaction_id: ref,
        kind: "status_mismatch",
        ledger_amount_minor_units: payment.amount_minor_units,
        gateway_amount_minor_units: gatewayTxn.amount_minor_units,
        gateway_status: gatewayTxn.status,
        gateway_settled_at: gatewayTxn.settled_at,
        details: `Gateway status "${gatewayTxn.status}" does not indicate a settled transaction.`,
      });
      continue;
    }

    if (gatewayTxn.amount_minor_units !== payment.amount_minor_units) {
      mismatches.push({
        run_id: runId,
        payment_id: payment.id,
        gateway_transaction_id: ref,
        kind: "amount_mismatch",
        ledger_amount_minor_units: payment.amount_minor_units,
        gateway_amount_minor_units: gatewayTxn.amount_minor_units,
        gateway_status: gatewayTxn.status,
        gateway_settled_at: gatewayTxn.settled_at,
        details: "Ledger and gateway amounts differ for the same reference.",
      });
    }
  }

  // The other direction: a gateway settlement with no matching local payment
  // at all (e.g. we never recorded it, or a duplicate on the gateway side).
  for (const gatewayTxn of settlementReport) {
    if (matchedGatewayIds.has(gatewayTxn.id)) continue;
    if (gatewayTxn.status !== "settled" && gatewayTxn.status !== "captured") continue;
    mismatches.push({
      run_id: runId,
      payment_id: null,
      gateway_transaction_id: gatewayTxn.id,
      kind: "missing_in_ledger",
      gateway_amount_minor_units: gatewayTxn.amount_minor_units,
      gateway_status: gatewayTxn.status,
      gateway_settled_at: gatewayTxn.settled_at,
      details: "Gateway settled this transaction but no local payment references it.",
    });
  }

  if (mismatches.length > 0) {
    const { error: insertError } = await admin.from("reconciliation_mismatches").insert(mismatches);
    if (insertError) {
      console.error("Failed to write reconciliation mismatches", insertError);
      return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not record mismatches." }), { status: 500 });
    }
  }

  return new Response(
    JSON.stringify({ run_id: runId, payments_checked: payments?.length ?? 0, gateway_records: settlementReport.length, mismatches_found: mismatches.length }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
