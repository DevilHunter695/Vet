// Supabase Edge Function: lifecycle notification detection (plan §6.5, N3).
//
// Invoked on a schedule (Supabase cron / pg_cron -> pg_net, per §6.5's
// scheduled-jobs section) rather than per-request. It only detects and
// queues — rows are inserted into `notifications` with sent_at left null;
// draining that queue into actual push sends is a separate job, out of
// scope here (see the plan's note on this function in TECHNICAL_PLAN.md).
//
// Runs with the service role key like payment-webhook: this is a trusted
// server context reading across users, which RLS would otherwise forbid.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const DORMANT_DAYS = 60;
const ABANDONED_CART_HOURS = 24;
const VACCINATION_WINDOW_DAYS = 7;
const RENEWAL_WINDOW_DAYS = 3;

interface QueuedNotification {
  user_id: string;
  category: string;
  title: string;
  body: string;
  sent_at: null;
}

/// Skips a category/user pair that already has an unsent (or very recently
/// queued) row — otherwise every run of this job re-queues the same
/// reminder, which is worse than not sending one at all.
async function alreadyQueuedRecently(userId: string, category: string): Promise<boolean> {
  const { data } = await supabase
    .from("notifications")
    .select("id")
    .eq("user_id", userId)
    .eq("category", category)
    .gte("created_at", new Date(Date.now() - VACCINATION_WINDOW_DAYS * 86_400_000).toISOString())
    .limit(1);
  return (data?.length ?? 0) > 0;
}

async function queue(rows: QueuedNotification[]) {
  if (rows.length === 0) return;
  const { error } = await supabase.from("notifications").insert(rows);
  if (error) console.error("Failed to queue notifications", error);
}

async function detectVaccinationsDue(): Promise<QueuedNotification[]> {
  const windowEnd = new Date(Date.now() + VACCINATION_WINDOW_DAYS * 86_400_000).toISOString();
  const { data: vaccinations } = await supabase
    .from("vaccinations")
    .select("user_id, vaccine_name, next_due_at, pets(name)")
    .lte("next_due_at", windowEnd)
    .gte("next_due_at", new Date().toISOString());

  const rows: QueuedNotification[] = [];
  for (const v of vaccinations ?? []) {
    if (await alreadyQueuedRecently(v.user_id, "vaccination_due")) continue;
    const petName = (v as any).pets?.name ?? "Your pet";
    rows.push({
      user_id: v.user_id,
      category: "vaccination_due",
      title: "Vaccination due soon",
      body: `${petName}'s ${v.vaccine_name} vaccination is due ${new Date(v.next_due_at).toDateString()}.`,
      sent_at: null,
    });
  }
  return rows;
}

async function detectRenewalsDue(): Promise<QueuedNotification[]> {
  const windowEnd = new Date(Date.now() + RENEWAL_WINDOW_DAYS * 86_400_000).toISOString();
  const { data: subscriptions } = await supabase
    .from("subscriptions")
    .select("user_id, renewal_date, plan_type")
    .eq("status", "active")
    .lte("renewal_date", windowEnd)
    .gte("renewal_date", new Date().toISOString());

  const rows: QueuedNotification[] = [];
  for (const s of subscriptions ?? []) {
    if (await alreadyQueuedRecently(s.user_id, "renewal_due")) continue;
    rows.push({
      user_id: s.user_id,
      category: "renewal_due",
      title: "Your plan renews soon",
      body: `Your ${s.plan_type} plan renews on ${new Date(s.renewal_date).toDateString()}.`,
      sent_at: null,
    });
  }
  return rows;
}

async function detectDormantUsers(): Promise<QueuedNotification[]> {
  const cutoff = new Date(Date.now() - DORMANT_DAYS * 86_400_000).toISOString();
  // A user is dormant if their most recent visit (of any status) predates the
  // cutoff, and they have no visit at all after it.
  const { data: users } = await supabase.from("users").select("id");
  const rows: QueuedNotification[] = [];
  for (const u of users ?? []) {
    const { data: recentVisits } = await supabase
      .from("visits")
      .select("id")
      .eq("user_id", u.id)
      .gte("scheduled_at", cutoff)
      .limit(1);
    if ((recentVisits?.length ?? 0) > 0) continue;

    const { data: anyVisit } = await supabase.from("visits").select("id").eq("user_id", u.id).limit(1);
    if ((anyVisit?.length ?? 0) === 0) continue; // never booked at all — not "dormant", just new

    if (await alreadyQueuedRecently(u.id, "dormant_winback")) continue;
    rows.push({
      user_id: u.id,
      category: "dormant_winback",
      title: "We miss you and your pet",
      body: "It's been a while since your last visit — book a check-up whenever you're ready.",
      sent_at: null,
    });
  }
  return rows;
}

async function detectAbandonedCarts(): Promise<QueuedNotification[]> {
  const cutoff = new Date(Date.now() - ABANDONED_CART_HOURS * 3_600_000).toISOString();
  const { data: carts } = await supabase.from("carts").select("id, user_id, updated_at").lte("updated_at", cutoff);

  const rows: QueuedNotification[] = [];
  for (const cart of carts ?? []) {
    const { data: items } = await supabase.from("cart_items").select("id").eq("cart_id", cart.id).limit(1);
    if ((items?.length ?? 0) === 0) continue; // empty cart, nothing abandoned

    if (await alreadyQueuedRecently(cart.user_id, "abandoned_cart")) continue;
    rows.push({
      user_id: cart.user_id,
      category: "abandoned_cart",
      title: "You left something in your cart",
      body: "Your booking is still saved — finish checkout whenever you're ready.",
      sent_at: null,
    });
  }
  return rows;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const [vaccinations, renewals, dormant, abandonedCarts] = await Promise.all([
    detectVaccinationsDue(),
    detectRenewalsDue(),
    detectDormantUsers(),
    detectAbandonedCarts(),
  ]);

  const allRows = [...vaccinations, ...renewals, ...dormant, ...abandonedCarts];
  await queue(allRows);

  return new Response(JSON.stringify({ queued: allRows.length }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
