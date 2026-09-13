"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { VISIT_STATUSES, type VisitRow } from "@/lib/types";

/// Calls admin_override_visit_status (migration 0015) rather than updating
/// `visits.status` directly — a plain UPDATE still has to pass through
/// enforce_visit_transition() (migration 0010) and would be rejected for
/// exactly the stuck-visit cases this panel exists to fix.
export default function VisitOverridePanel({ visits }: { visits: VisitRow[] }) {
  const supabase = createClient();
  const router = useRouter();
  const [openId, setOpenId] = useState<string | null>(null);
  const [newStatus, setNewStatus] = useState<string>(VISIT_STATUSES[0]);
  const [reason, setReason] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function openFor(visit: VisitRow) {
    setOpenId(visit.id);
    setNewStatus(visit.status);
    setReason("");
    setError(null);
  }

  async function submitOverride(visit: VisitRow) {
    if (!reason.trim()) {
      setError("A reason is required for an override.");
      return;
    }
    setBusyId(visit.id);
    setError(null);
    const { error } = await supabase.rpc("admin_override_visit_status", {
      p_visit_id: visit.id,
      p_new_status: newStatus,
      p_reason: reason.trim(),
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
    return <p className="muted">No visits yet.</p>;
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
            <span className={`badge ${visit.status}`}>{visit.status}</span>
          </div>

          {openId === visit.id ? (
            <div style={{ marginTop: 10 }}>
              <div className="row" style={{ justifyContent: "flex-start", gap: 8 }}>
                <select value={newStatus} onChange={(e) => setNewStatus(e.target.value)}>
                  {VISIT_STATUSES.map((status) => (
                    <option key={status} value={status}>
                      {status}
                    </option>
                  ))}
                </select>
                <input
                  type="text"
                  placeholder="Reason for override"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  style={{ flex: 1 }}
                />
              </div>
              <div className="row" style={{ marginTop: 8, justifyContent: "flex-start", gap: 8 }}>
                <button onClick={() => submitOverride(visit)} disabled={busyId === visit.id}>
                  {busyId === visit.id ? "Overriding…" : "Override"}
                </button>
                <button className="secondary" onClick={() => setOpenId(null)} disabled={busyId === visit.id}>
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <div className="row" style={{ marginTop: 10, justifyContent: "flex-start" }}>
              <button onClick={() => openFor(visit)}>Override status</button>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
