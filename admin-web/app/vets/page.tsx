import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";
import VetsTable from "@/components/VetsTable";

export default async function VetsPage() {
  const { supabase } = await requireAdmin();
  const { data: vets } = await supabase.from("vets").select("*").order("created_at", { ascending: false });

  return (
    <div className="container">
      <h1>Vets</h1>
      <NavTabs />
      <p className="muted">
        Manually verify each vet&apos;s veterinary council registration number before approving —
        this is the platform&apos;s real trust layer, not something to automate early.
      </p>
      <VetsTable initialVets={vets ?? []} />
    </div>
  );
}
