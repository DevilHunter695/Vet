// Supabase Edge Function: POST (plan J8) — transactional SMS/WhatsApp
// fallback when a push notification failed or the recipient has push
// disabled.
//
// HONEST SCOPE NOTE: this codebase has no third-party SMS/WhatsApp gateway
// account (Twilio, MSG91, Gupshup, etc) or API key configured. Sending a
// real text message is therefore explicitly out of scope here — see the
// TODO block below for exactly where that call would go once credentials
// exist. What this function *does* do for real: authenticates the caller,
// validates the payload, and writes an append-only audit row to
// `sms_fallback_log` via the service role — the same trusted-boundary
// pattern as issue-refund/issue-support-refund (money/comms creation is
// never a direct client insert; a service-role function is the only
// writer).
//
// Called from `SupabaseSMSFallbackRepository.sendFallback`, which is in
// turn driven by `NotificationDeliveryPolicy` / `SendTransactionalNotificationUseCase`
// on the client (VetCircuit/Domain/UseCases/UseCases.swift) whenever push
// isn't viable for a transactional notification.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const VALID_REASONS = ["no_push_token", "push_delivery_failed", "push_disabled_by_user"];

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const { user_id, phone, category, body, reason } = await req.json();
  if (!user_id || !phone || !category || !body || !reason) {
    return new Response(
      JSON.stringify({ code: "VALIDATION", message: "user_id, phone, category, body, and reason are required." }),
      { status: 400 },
    );
  }
  if (!VALID_REASONS.includes(reason)) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: `reason must be one of ${VALID_REASONS.join(", ")}.` }), { status: 400 });
  }

  // Authenticate the caller and require they're only ever logging a
  // fallback for themselves — this endpoint is not an ops/broadcast tool.
  const userClient = createClient(supabaseUrl, serviceRoleKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });
  if (userData.user.id !== user_id) {
    return new Response(JSON.stringify({ code: "FORBIDDEN", message: "Cannot log a fallback for another user." }), { status: 403 });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey);

  // ---------------------------------------------------------------------
  // TODO(SMS/WhatsApp gateway): this is where a real send would happen,
  // e.g.:
  //
  //   const twilioResponse = await fetch(
  //     `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
  //     { method: "POST", headers: {...}, body: new URLSearchParams({ To: phone, From: fromNumber, Body: body }) }
  //   );
  //
  // No TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN (or equivalent MSG91/Gupshup
  // credentials) are configured for this project, so nothing is actually
  // dispatched — only the intent is recorded below.
  // ---------------------------------------------------------------------

  const { data: row, error } = await admin
    .from("sms_fallback_log")
    .insert({ user_id, phone, category, body, reason })
    .select()
    .single();

  if (error || !row) {
    console.error("Failed to record SMS fallback", error);
    return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not record the SMS fallback." }), { status: 500 });
  }

  return new Response(JSON.stringify(row), { status: 200, headers: { "Content-Type": "application/json" } });
});
