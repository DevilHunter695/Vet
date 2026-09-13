// Supabase Edge Function: POST /v1/account/delete (plan Appendix A, A6).
// App Store guideline 5.1.1(v): account deletion must be reachable in-app.
// Runs as a trusted server context so it can enforce "one pending request
// per user" and, later, immediately pause the account (block new bookings)
// in the same call.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SOFT_WINDOW_DAYS = 30;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const userClient = createClient(supabaseUrl, serviceRoleKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const scheduledPurgeAt = new Date(Date.now() + SOFT_WINDOW_DAYS * 24 * 3600 * 1000).toISOString();

  const { data, error } = await admin
    .from("deletion_requests")
    .insert({ user_id: userData.user.id, scheduled_purge_at: scheduledPurgeAt })
    .select()
    .single();

  if (error) {
    // The partial unique index raises a conflict if one's already pending.
    return new Response(JSON.stringify({ code: "ALREADY_PENDING", message: "A deletion request is already pending." }), { status: 409 });
  }

  return new Response(JSON.stringify(data), { status: 200, headers: { "Content-Type": "application/json" } });
});
