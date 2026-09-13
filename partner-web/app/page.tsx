import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import VisitsBoard from "@/components/VisitsBoard";
import SignOutButton from "@/components/SignOutButton";

export default async function DashboardPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: vet } = await supabase
    .from("vets")
    .select("*")
    .eq("auth_id", user!.id)
    .single();

  if (!vet) {
    return (
      <div className="container">
        <h1>Verification pending</h1>
        <p className="muted">
          Your account isn&apos;t linked to a verified vet profile yet. The VetCircuit team
          manually verifies every vet&apos;s council registration before they can go live — check
          back once that&apos;s complete.
        </p>
        <SignOutButton />
      </div>
    );
  }

  const { data: circuits } = await supabase
    .from("circuits")
    .select("*, schedule_slots(*)")
    .eq("vet_id", vet.id);

  const { data: visits } = await supabase
    .from("visits")
    .select("*, pets(name, species)")
    .eq("vet_id", vet.id)
    .order("scheduled_at", { ascending: true });

  return (
    <div className="container">
      <div className="row" style={{ marginBottom: 24 }}>
        <div>
          <h1>Welcome, {vet.name}</h1>
          <p className="muted">
            {vet.verification_status === "verified" ? "Verified partner" : "Verification " + vet.verification_status}
            {" · "}
            {vet.rating.toFixed(1)}★ ({vet.review_count} reviews)
          </p>
        </div>
        <div className="row" style={{ gap: 8 }}>
          <Link href="/earnings"><button className="secondary">Earnings</button></Link>
          <SignOutButton />
        </div>
      </div>

      <section style={{ marginBottom: 32 }}>
        <h2>Your circuit</h2>
        {(circuits ?? []).length === 0 ? (
          <p className="muted">No circuit set up yet. Contact the VetCircuit team to configure your cluster area and schedule.</p>
        ) : (
          circuits!.map((circuit) => (
            <div key={circuit.id} className="card">
              <strong>{circuit.cluster_area}</strong>
              <p className="muted">{circuit.schedule_slots?.length ?? 0} scheduled slot(s)</p>
            </div>
          ))
        )}
      </section>

      <section>
        <h2>Visits</h2>
        <VisitsBoard initialVisits={visits ?? []} />
      </section>
    </div>
  );
}
