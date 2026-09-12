import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";
import SignOutButton from "@/components/SignOutButton";

export default async function OverviewPage() {
  const { supabase } = await requireAdmin();

  const [
    { count: userCount },
    { count: vetCount },
    { count: pendingVetCount },
    { count: circuitCount },
    { count: activeVisitCount },
    { count: completedVisitCount },
    { count: activeSubscriptionCount },
  ] = await Promise.all([
    supabase.from("users").select("*", { count: "exact", head: true }),
    supabase.from("vets").select("*", { count: "exact", head: true }),
    supabase.from("vets").select("*", { count: "exact", head: true }).eq("verification_status", "pending"),
    supabase.from("circuits").select("*", { count: "exact", head: true }),
    supabase.from("visits").select("*", { count: "exact", head: true }).in("status", ["requested", "confirmed", "en_route"]),
    supabase.from("visits").select("*", { count: "exact", head: true }).eq("status", "completed"),
    supabase.from("subscriptions").select("*", { count: "exact", head: true }).eq("status", "active"),
  ]);

  const stats = [
    { label: "Customers", value: userCount ?? 0 },
    { label: "Vets", value: vetCount ?? 0 },
    { label: "Pending verification", value: pendingVetCount ?? 0 },
    { label: "Circuits", value: circuitCount ?? 0 },
    { label: "Active visits", value: activeVisitCount ?? 0 },
    { label: "Completed visits", value: completedVisitCount ?? 0 },
    { label: "Active subscriptions", value: activeSubscriptionCount ?? 0 },
  ];

  return (
    <div className="container">
      <div className="row">
        <h1>VetCircuit Admin</h1>
        <SignOutButton />
      </div>
      <NavTabs />
      <div className="stats">
        {stats.map((stat) => (
          <div key={stat.label} className="stat">
            <div className="value">{stat.value}</div>
            <div className="label">{stat.label}</div>
          </div>
        ))}
      </div>
      {(pendingVetCount ?? 0) > 0 && (
        <p className="muted">
          {pendingVetCount} vet{(pendingVetCount ?? 0) === 1 ? "" : "s"} waiting on manual verification —
          see the <a href="/vets">Vets</a> tab.
        </p>
      )}
    </div>
  );
}
