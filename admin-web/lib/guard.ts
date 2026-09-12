import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

/// Every admin page calls this first. It's a UX gate only — the real
/// authorization boundary is the `is_admin()` check inside RLS policies
/// (backend/supabase/migrations/0001_init.sql), so an admin query still
/// returns nothing for a non-admin even if this check were bypassed.
export async function requireAdmin() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: adminRow } = await supabase.from("admins").select("user_id").eq("user_id", user!.id).maybeSingle();
  if (!adminRow) redirect("/login?error=not_admin");

  return { supabase, user: user! };
}
