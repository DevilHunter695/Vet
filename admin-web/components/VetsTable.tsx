"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Vet } from "@/lib/types";

export default function VetsTable({ initialVets }: { initialVets: Vet[] }) {
  const supabase = createClient();
  const [vets, setVets] = useState(initialVets);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function setStatus(vet: Vet, status: Vet["verification_status"]) {
    setBusyId(vet.id);
    setError(null);
    // Only an admin's RLS policy ("vets update own") permits this write for
    // a vet row that isn't their own.
    const { error } = await supabase.from("vets").update({ verification_status: status }).eq("id", vet.id);
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    setVets((prev) => prev.map((v) => (v.id === vet.id ? { ...v, verification_status: status } : v)));
  }

  if (vets.length === 0) {
    return <p className="muted">No vets onboarded yet.</p>;
  }

  return (
    <div>
      {error && <p style={{ color: "#c0392b", fontSize: 13, marginBottom: 12 }}>{error}</p>}
      {vets.map((vet) => (
        <div key={vet.id} className="card">
          <div className="row">
            <div>
              <strong>{vet.name}</strong>{" "}
              <span className="muted">License #{vet.license_number}</span>
            </div>
            <span className={`badge ${vet.verification_status}`}>{vet.verification_status}</span>
          </div>
          <p className="muted" style={{ marginTop: 6 }}>
            {vet.rating.toFixed(1)}★ ({vet.review_count} reviews)
          </p>
          <div className="row" style={{ marginTop: 10, justifyContent: "flex-start", gap: 8 }}>
            {vet.verification_status !== "verified" && (
              <button onClick={() => setStatus(vet, "verified")} disabled={busyId === vet.id}>
                Approve
              </button>
            )}
            {vet.verification_status !== "rejected" && (
              <button className="danger" onClick={() => setStatus(vet, "rejected")} disabled={busyId === vet.id}>
                Reject
              </button>
            )}
            {vet.verification_status !== "pending" && (
              <button className="secondary" onClick={() => setStatus(vet, "pending")} disabled={busyId === vet.id}>
                Reset to pending
              </button>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
