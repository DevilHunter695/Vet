import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";
import FlagsTable from "@/components/FlagsTable";

/// Kill switches per feature (plan §R, §7.1) — a flag flip here is meant to
/// be the fast path for turning off a misbehaving feature in production
/// without a deploy.
export default async function FlagsPage() {
  const { supabase } = await requireAdmin();
  const { data: flags } = await supabase.from("feature_flags").select("*").order("name", { ascending: true });

  return (
    <div className="container">
      <h1>Flags</h1>
      <NavTabs />
      <p className="muted">Toggling a flag off here takes effect on the next client read — no deploy required.</p>
      <FlagsTable initialFlags={flags ?? []} />
    </div>
  );
}
