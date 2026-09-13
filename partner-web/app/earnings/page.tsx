import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import SignOutButton from "@/components/SignOutButton";
import type { Payout, VetLedgerEntry } from "@/lib/types";

function formatRupees(minorUnits: number) {
  return (minorUnits / 100).toLocaleString("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 });
}

// G7: vet payouts — "Vets quit over late/unclear pay faster than over
// anything else." Every completed visit's earning, and what's already
// been paid out, in one place.
export default async function EarningsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: vet } = await supabase.from("vets").select("*").eq("auth_id", user!.id).single();
  if (!vet) redirect("/");

  const { data: ledger } = await supabase
    .from("vet_ledger")
    .select("*")
    .eq("vet_id", vet.id)
    .order("created_at", { ascending: false });

  const { data: payouts } = await supabase
    .from("payouts")
    .select("*")
    .eq("vet_id", vet.id)
    .order("period_end", { ascending: false });

  const ledgerEntries = (ledger ?? []) as VetLedgerEntry[];
  const payoutRuns = (payouts ?? []) as Payout[];

  const unpaidTotal = ledgerEntries
    .filter((entry) => entry.payout_id === null)
    .reduce((sum, entry) => sum + entry.amount_minor_units, 0);

  return (
    <div className="container">
      <div className="row" style={{ marginBottom: 24 }}>
        <div>
          <h1>Earnings</h1>
          <p className="muted">{vet.name}</p>
        </div>
        <SignOutButton />
      </div>

      <section className="card" style={{ marginBottom: 32 }}>
        <p className="muted">Owed to you, not yet paid out</p>
        <h2 style={{ margin: "4px 0 0" }}>{formatRupees(unpaidTotal)}</h2>
      </section>

      <section style={{ marginBottom: 32 }}>
        <h2>Payout history</h2>
        {payoutRuns.length === 0 ? (
          <p className="muted">No payout runs yet — the weekly payout job batches unpaid earnings into a run.</p>
        ) : (
          payoutRuns.map((payout) => (
            <div key={payout.id} className="card">
              <div className="row">
                <div>
                  <strong>{formatRupees(payout.amount_minor_units)}</strong>{" "}
                  <span className="muted">
                    {new Date(payout.period_start).toLocaleDateString()} – {new Date(payout.period_end).toLocaleDateString()}
                  </span>
                </div>
                <span className={`badge ${payout.status}`}>{payout.status}</span>
              </div>
            </div>
          ))
        )}
      </section>

      <section>
        <h2>Recent activity</h2>
        {ledgerEntries.length === 0 ? (
          <p className="muted">Earnings appear here as soon as a visit completes.</p>
        ) : (
          ledgerEntries.slice(0, 20).map((entry) => (
            <div key={entry.id} className="card">
              <div className="row">
                <div>
                  <strong>{entry.description}</strong>{" "}
                  <span className="muted">{new Date(entry.created_at).toLocaleDateString()}</span>
                </div>
                <span>{formatRupees(entry.amount_minor_units)}</span>
              </div>
            </div>
          ))
        )}
      </section>
    </div>
  );
}
