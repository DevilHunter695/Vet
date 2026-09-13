import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";
import RunPayoutsButton from "@/components/RunPayoutsButton";
import type { PayoutRow } from "@/lib/types";

function formatRupees(minorUnits: number) {
  return (minorUnits / 100).toLocaleString("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 });
}

/// Q: "payout run" — the plan calls the ops console "the most underrated
/// P0 surface"; without it, running weekly payouts means hand-editing the
/// production database (§Q's own warning).
export default async function PayoutsPage() {
  const { supabase } = await requireAdmin();

  const { data: unpaidRows } = await supabase
    .from("vet_ledger")
    .select("vet_id, amount_minor_units, vets(name)")
    .is("payout_id", null);

  const unpaidByVet = new Map<string, { name: string; total: number }>();
  for (const row of unpaidRows ?? []) {
    const vetName = (row as unknown as { vets?: { name: string } }).vets?.name ?? "Unknown vet";
    const existing = unpaidByVet.get(row.vet_id) ?? { name: vetName, total: 0 };
    existing.total += row.amount_minor_units;
    unpaidByVet.set(row.vet_id, existing);
  }

  const { data: payouts } = await supabase
    .from("payouts")
    .select("*, vets(name)")
    .order("created_at", { ascending: false })
    .limit(50);

  return (
    <div className="container">
      <h1>Payouts</h1>
      <NavTabs />

      <section className="card" style={{ marginBottom: 24 }}>
        <p className="muted">
          Batches every vet&apos;s unpaid ledger balance into a payout row per vet. Actually transferring the
          money still happens through the payment gateway&apos;s payout API — this marks what&apos;s owed as
          swept, it doesn&apos;t itself move funds.
        </p>
        <RunPayoutsButton />
      </section>

      <section style={{ marginBottom: 32 }}>
        <h2>Currently owed</h2>
        {unpaidByVet.size === 0 ? (
          <p className="muted">Nothing outstanding right now.</p>
        ) : (
          Array.from(unpaidByVet.entries()).map(([vetId, entry]) => (
            <div key={vetId} className="card">
              <div className="row">
                <strong>{entry.name}</strong>
                <span>{formatRupees(entry.total)}</span>
              </div>
            </div>
          ))
        )}
      </section>

      <section>
        <h2>Payout runs</h2>
        {(payouts ?? []).length === 0 ? (
          <p className="muted">No payout runs yet.</p>
        ) : (
          (payouts as PayoutRow[]).map((payout) => (
            <div key={payout.id} className="card">
              <div className="row">
                <div>
                  <strong>{payout.vets?.name ?? "Vet"}</strong>{" "}
                  <span className="muted">
                    {new Date(payout.period_start).toLocaleDateString()} – {new Date(payout.period_end).toLocaleDateString()}
                  </span>
                </div>
                <div className="row" style={{ gap: 8 }}>
                  <span>{formatRupees(payout.amount_minor_units)}</span>
                  <span className={`badge ${payout.status}`}>{payout.status}</span>
                </div>
              </div>
            </div>
          ))
        )}
      </section>
    </div>
  );
}
