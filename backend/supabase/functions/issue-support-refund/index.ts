// Supabase Edge Function: POST (plan M4) — a support agent issuing a
// refund or wallet credit against a visit, from a ticket, with an
// append-only audit trail.
//
// Same trusted-boundary discipline as issue-refund/index.ts: refunds and
// wallet_ledger are both money creation, so neither is INSERTed by the
// client (RLS on both is select-only for every client role). This function
// is the only writer for the support-issued path, and it additionally
// writes support_refund_audit — which has NO client insert policy at all —
// recording who issued it, why, against which ticket/visit, and when.
//
// Unlike issue-refund (callable by the visit's own owner for a
// self-service cancellation refund), this endpoint is admin/support-only:
// a customer can never issue their own refund from a ticket.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const { ticket_id, visit_id, kind, amount_minor_units, reason } = await req.json();
  if (!ticket_id || !visit_id || !kind || !amount_minor_units || !reason) {
    return new Response(
      JSON.stringify({ code: "VALIDATION", message: "ticket_id, visit_id, kind, amount_minor_units, and reason are required." }),
      { status: 400 },
    );
  }
  if (kind !== "refund" && kind !== "wallet_credit") {
    return new Response(JSON.stringify({ code: "VALIDATION", message: "kind must be 'refund' or 'wallet_credit'." }), { status: 400 });
  }
  if (typeof amount_minor_units !== "number" || amount_minor_units <= 0) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: "amount_minor_units must be a positive number." }), { status: 400 });
  }

  const userClient = createClient(supabaseUrl, serviceRoleKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const admin = createClient(supabaseUrl, serviceRoleKey);

  // Authorize: admin/support-role only — never the ticket's own author.
  const { data: adminRow } = await admin.from("admins").select("user_id").eq("user_id", userData.user.id).maybeSingle();
  if (!adminRow) {
    return new Response(JSON.stringify({ code: "FORBIDDEN" }), { status: 403 });
  }

  // The ticket must exist and be tied to the visit being refunded/credited,
  // so the audit trail is never pointed at a mismatched pair.
  const { data: ticket } = await admin.from("support_tickets").select("id, visit_id").eq("id", ticket_id).maybeSingle();
  if (!ticket) {
    return new Response(JSON.stringify({ code: "NOT_FOUND", message: "Ticket not found." }), { status: 404 });
  }
  if (ticket.visit_id && ticket.visit_id !== visit_id) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: "visit_id does not match the ticket." }), { status: 400 });
  }

  const { data: visit } = await admin.from("visits").select("id, user_id").eq("id", visit_id).maybeSingle();
  if (!visit) {
    return new Response(JSON.stringify({ code: "NOT_FOUND", message: "Visit not found." }), { status: 404 });
  }

  let refundId: string | null = null;
  let walletLedgerEntryId: string | null = null;

  if (kind === "refund") {
    // Reuse the same payments row a self-service refund would use; a real
    // deployment resolves the visit's actual payment_id and calls the
    // gateway's refund API before writing this row (same TODO issue-refund
    // already carries).
    const { data: payment } = await admin.from("payments").select("id").eq("visit_id", visit_id).maybeSingle();
    const { data: refund, error: refundError } = await admin
      .from("refunds")
      .insert({
        visit_id,
        payment_id: payment?.id ?? null,
        amount_minor_units,
        reason,
        status: "processed",
        initiated_by_ops_user_id: userData.user.id,
      })
      .select()
      .single();
    if (refundError || !refund) {
      return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not issue refund." }), { status: 500 });
    }
    refundId = refund.id;
  } else {
    const { data: entry, error: ledgerError } = await admin
      .from("wallet_ledger")
      .insert({
        user_id: visit.user_id,
        amount_minor_units, // positive = credit
        reason,
        related_visit_id: visit_id,
      })
      .select()
      .single();
    if (ledgerError || !entry) {
      return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not issue wallet credit." }), { status: 500 });
    }
    walletLedgerEntryId = entry.id;
  }

  const { data: audit, error: auditError } = await admin
    .from("support_refund_audit")
    .insert({
      ticket_id,
      visit_id,
      issued_by_user_id: userData.user.id,
      kind,
      amount_minor_units,
      reason,
      refund_id: refundId,
      wallet_ledger_entry_id: walletLedgerEntryId,
    })
    .select()
    .single();

  if (auditError || !audit) {
    // The money movement above already succeeded and is itself an
    // append-only, immutable record — surface this as a distinct failure
    // rather than silently dropping the audit trail.
    return new Response(JSON.stringify({ code: "UNKNOWN", message: "Refund/credit issued but the audit record failed to write." }), { status: 500 });
  }

  return new Response(JSON.stringify(audit), { status: 200, headers: { "Content-Type": "application/json" } });
});
