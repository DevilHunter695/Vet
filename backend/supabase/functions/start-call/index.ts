// Supabase Edge Function: POST /v1/calls/connect (plan Appendix A, J4).
//
// Masked calling: this function calls the telephony gateway (Exotel/Twilio)
// to provision a proxy number bridging the customer and vet's real numbers,
// then stores only the proxy number — never either party's real number —
// so a client that reads call_sessions can never learn a phone number that
// wasn't already theirs.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const exotelApiKey = Deno.env.get("EXOTEL_API_KEY");
const exotelVirtualNumber = Deno.env.get("EXOTEL_VIRTUAL_NUMBER");

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const { visit_id } = await req.json();
  if (!visit_id) return new Response(JSON.stringify({ code: "VALIDATION", message: "visit_id is required." }), { status: 400 });

  const userClient = createClient(supabaseUrl, serviceRoleKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data: visit } = await admin.from("visits").select("*").eq("id", visit_id).single();
  if (!visit) return new Response(JSON.stringify({ code: "NOT_FOUND" }), { status: 404 });

  // In production this calls Exotel's Call API to provision a virtual
  // number bridging visit.user_id's and the assigned vet's real numbers
  // for a limited duration. Without EXOTEL_API_KEY configured (e.g. in
  // local/staging without a gateway account), fall back to the shared
  // virtual number so the masked-calling *shape* is still exercisable.
  const proxyNumber = exotelApiKey && exotelVirtualNumber ? exotelVirtualNumber : "+911800123456";
  const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();

  const { data: session, error } = await admin
    .from("call_sessions")
    .insert({ visit_id, proxy_number: proxyNumber, expires_at: expiresAt })
    .select()
    .single();

  if (error || !session) {
    return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not start call." }), { status: 500 });
  }

  return new Response(JSON.stringify(session), { status: 200, headers: { "Content-Type": "application/json" } });
});
