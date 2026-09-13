"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { VisitRow } from "@/lib/types";

function formatRupees(minorUnits: number) {
  return (minorUnits / 100).toLocaleString("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 });
}

/// Calls the issue-refund Edge Function rather than writing to `refunds`
/// directly — that table is select-only under RLS (migration 0009); the
/// function is the sole writer and is what actually authorizes an admin.
export default function RefundPanel({ visits }: { visits: VisitRow[] }) {
  const supabase = createClient();
  const router = useRouter();
  const [openId, setOpenId] = useState<string | null>(null);
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function openFor(visit: VisitRow) {
    setOpenId(visit.id);
    setAmount(visit.payments ? String(visit.payments.amount_minor_units / 100) : "");
    setReason("");
    setError(null);
  }

  async function submitRefund(visit: VisitRow) {
    if (!visit.payment_id) return;
    const rupees = Number(amount);
    if (!rupees || rupees <= 0) {
      setError("Enter a refund amount greater than zero.");
      return;
    }
    if (!reason.trim()) {
      setError("A reason is required.");
      return;
    }

    setBusyId(visit.id);
    setError(null);
    const { error } = await supabase.functions.invoke("issue-refund", {
      body: {
        visit_id: visit.id,
        payment_id: visit.payment_id,
        amount_minor_units: Math.round(rupees * 100),
        reason: reason.trim(),
      },
    });
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    setOpenId(null);
    router.refresh();
  }

  if (visits.length === 0) {
    return <p className="muted">No completed or cancelled visits with a payment in the recent window.</p>;
  }

  return (
    <div>
      {error && <p style={{ color: "#c0392b", fontSize: 13, marginBottom: 12 }}>{error}</p>}
      {visits.map((visit) => (
        <div key={visit.id} className="card">
          <div className="row">
            <div>
              <strong>{visit.vets?.name ?? "Vet"}</strong>{" "}
              <span className="muted">
                {new Date(visit.scheduled_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
              </span>
            </div>
            <div className="row" style={{ gap: 8 }}>
              <span className={`badge ${visit.status}`}>{visit.status}</span>
              {visit.payments && <span>{formatRupees(visit.payments.amount_minor_units)}</span>}
            </div>
          </div>

          {!visit.payment_id ? (
            <p className="muted" style={{ marginTop: 8 }}>No payment on this visit.</p>
          ) : openId === visit.id ? (
            <div style={{ marginTop: 10 }}>
              <div className="row" style={{ justifyContent: "flex-start", gap: 8 }}>
                <input
                  type="number"
                  min="0"
                  step="1"
                  placeholder="Amount (INR)"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  style={{ width: 140 }}
                />
                <input
                  type="text"
                  placeholder="Reason"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  style={{ flex: 1 }}
                />
              </div>
              <div className="row" style={{ marginTop: 8, justifyContent: "flex-start", gap: 8 }}>
                <button onClick={() => submitRefund(visit)} disabled={busyId === visit.id}>
                  {busyId === visit.id ? "Refunding…" : "Refund"}
                </button>
                <button className="secondary" onClick={() => setOpenId(null)} disabled={busyId === visit.id}>
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <div className="row" style={{ marginTop: 10, justifyContent: "flex-start" }}>
              <button onClick={() => openFor(visit)}>Issue refund</button>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
