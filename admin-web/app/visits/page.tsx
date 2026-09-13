import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";
import VisitOverridePanel from "@/components/VisitOverridePanel";
import type { VisitRow } from "@/lib/types";

/// Manual status override (plan §Q: "manual status override (audited)").
/// The state machine (migration 0010) is deliberately strict — this page
/// exists for the visits it strands, not as a general-purpose editor.
export default async function VisitsPage() {
  const { supabase } = await requireAdmin();
  const { data: visits } = await supabase
    .from("visits")
    .select("*, vets(name)")
    .order("scheduled_at", { ascending: false })
    .limit(50);

  return (
    <div className="container">
      <h1>Visits</h1>
      <NavTabs />
      <p className="muted">
        Overriding a status bypasses the normal transition rules — it&apos;s logged to visit_events with
        the reason you give, so use it only to unstick a visit the normal flow can&apos;t reach.
      </p>
      <VisitOverridePanel visits={(visits ?? []) as VisitRow[]} />
    </div>
  );
}
