import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";

export default async function CircuitsPage() {
  const { supabase } = await requireAdmin();
  const { data: circuits } = await supabase
    .from("circuits")
    .select("*, vets(name), schedule_slots(id)")
    .order("created_at", { ascending: false });

  return (
    <div className="container">
      <h1>Circuits</h1>
      <NavTabs />
      {(circuits ?? []).length === 0 ? (
        <p className="muted">No circuits configured yet.</p>
      ) : (
        circuits!.map((circuit) => (
          <div key={circuit.id} className="card">
            <div className="row">
              <div>
                <strong>{circuit.cluster_area}</strong>{" "}
                <span className="muted">· {circuit.vets?.name ?? "Unassigned vet"}</span>
              </div>
              <span className="muted">{circuit.schedule_slots?.length ?? 0} slots</span>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
