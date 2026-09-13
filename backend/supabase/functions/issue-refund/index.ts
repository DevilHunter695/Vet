// Supabase Edge Function: POST /v1/refunds (plan Appendix A, §6.2).
//
// Refunds are money creation — §6.2's trusted-boundary table lists them
// explicitly. Neither the customer app's automatic cancellation refund nor
// an ops-initiated one may INSERT the refunds row directly (RLS on that
// table is select-only for every client role); this function is the only
// writer, for both paths.
//
// A real deployment also calls the payment gateway's refund API here and
// only writes the row after that call succeeds — that integration is a
// TODO tracked in the plan (G4 is P0; the gateway call itself needs a
// Razorpay account to test against).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const { visit_id, payment_id, amount_minor_units, reason } = await req.json();
  if (!visit_id || !payment_id || !amount_minor_units || !reason) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: "visit_id, payment_id, amount_minor_units, and reason are required." }), { status: 400 });
  }

  const userClient = createClient(supabaseUrl, serviceRoleKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const admin = createClient(supabaseUrl, serviceRoleKey);

  // Authorize: either the requester owns the visit (their own cancellation
  // refund) or is an admin (ops-initiated). Everyone else is refused.
  const { data: visit } = await admin.from("visits").select("user_id").eq("id", visit_id).single();
  const { data: adminRow } = await admin.from("admins").select("user_id").eq("user_id", userData.user.id).maybeSingle();
  const isOwner = visit?.user_id === userData.user.id;
  const isAdmin = !!adminRow;
  if (!isOwner && !isAdmin) {
    return new Response(JSON.stringify({ code: "FORBIDDEN" }), { status: 403 });
  }

  const { data: refund, error } = await admin
    .from("refunds")
    .insert({
      visit_id, payment_id, amount_minor_units, reason, status: "processed",
      initiated_by_ops_user_id: isAdmin && !isOwner ? userData.user.id : null,
    })
    .select()
    .single();

  if (error || !refund) {
    return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not issue refund." }), { status: 500 });
  }

  return new Response(JSON.stringify(refund), { status: 200, headers: { "Content-Type": "application/json" } });
});
