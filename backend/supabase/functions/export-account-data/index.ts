// Supabase Edge Function: GET /v1/account/export (plan Appendix A, A7).
// A DPDP data-principal right — assembles everything the plan's data model
// attributes to one user into a single JSON document.
//
// The plan's Appendix A models this as an async job returning a signed
// download URL once ready; this synchronous version is a same-shape
// stand-in until real volumes justify the async path.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const userClient = createClient(supabaseUrl, serviceRoleKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ code: "UNAUTHENTICATED" }), { status: 401 });

  const userId = userData.user.id;
  const admin = createClient(supabaseUrl, serviceRoleKey);

  const [{ data: user }, { data: addresses }, { data: visits }, { data: consents }] = await Promise.all([
    admin.from("users").select("*, pets(*)").eq("id", userId).single(),
    admin.from("addresses").select("*").eq("owner_id", userId),
    admin.from("visits").select("*").eq("user_id", userId),
    admin.from("consents").select("*").eq("user_id", userId),
  ]);

  const exportPayload = {
    user,
    addresses: addresses ?? [],
    visits: visits ?? [],
    consents: consents ?? [],
    generatedAt: new Date().toISOString(),
  };

  return new Response(JSON.stringify(exportPayload), { status: 200, headers: { "Content-Type": "application/json" } });
});
