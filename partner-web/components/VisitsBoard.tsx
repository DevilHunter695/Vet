"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Visit, VisitStatus } from "@/lib/types";

const NEXT_STATUS: Partial<Record<VisitStatus, VisitStatus>> = {
  requested: "confirmed",
  confirmed: "en_route",
  en_route: "completed",
};

const NEXT_LABEL: Partial<Record<VisitStatus, string>> = {
  requested: "Confirm",
  confirmed: "Start visit (en route)",
  en_route: "Mark completed",
};

export default function VisitsBoard({ initialVisits }: { initialVisits: Visit[] }) {
  const supabase = createClient();
  const [visits, setVisits] = useState(initialVisits);
  const [notesDraft, setNotesDraft] = useState<Record<string, string>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function advanceStatus(visit: Visit) {
    const nextStatus = NEXT_STATUS[visit.status];
    if (!nextStatus) return;
    setBusyId(visit.id);
    setError(null);

    const update: Partial<Visit> = { status: nextStatus };
    if (nextStatus === "completed") {
      update.completed_at = new Date().toISOString();
      update.notes = notesDraft[visit.id] ?? visit.notes ?? undefined;
    }

    // RLS (visits update by vet policy) restricts this to the assigned vet.
    const { error } = await supabase.from("visits").update(update).eq("id", visit.id);
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    setVisits((prev) => prev.map((v) => (v.id === visit.id ? { ...v, ...update } as Visit : v)));
  }

  async function cancelVisit(visit: Visit) {
    setBusyId(visit.id);
    const { error } = await supabase.from("visits").update({ status: "cancelled" }).eq("id", visit.id);
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    setVisits((prev) => prev.map((v) => (v.id === visit.id ? { ...v, status: "cancelled" } : v)));
  }

  if (visits.length === 0) {
    return <p className="muted">No visits yet. They&apos;ll show up here as customers book your circuit.</p>;
  }

  return (
    <div>
      {error && <p style={{ color: "#c0392b", fontSize: 13, marginBottom: 12 }}>{error}</p>}
      {visits.map((visit) => (
        <div key={visit.id} className="card">
          <div className="row">
            <div>
              <strong>{visit.pets?.name ?? "Pet"}</strong>{" "}
              <span className="muted">
                {new Date(visit.scheduled_at).toLocaleString(undefined, {
                  dateStyle: "medium",
                  timeStyle: "short",
                })}
              </span>
            </div>
            <span className={`badge ${visit.status}`}>{visit.status.replace("_", " ")}</span>
          </div>

          {visit.status === "en_route" && (
            <textarea
              placeholder="Visit notes (vaccination record, observations, etc.)"
              value={notesDraft[visit.id] ?? visit.notes ?? ""}
              onChange={(e) => setNotesDraft((prev) => ({ ...prev, [visit.id]: e.target.value }))}
              rows={2}
              style={{ marginTop: 10 }}
            />
          )}

          {visit.status === "completed" && visit.notes && (
            <p className="muted" style={{ marginTop: 10 }}>{visit.notes}</p>
          )}

          <div className="row" style={{ marginTop: 10, justifyContent: "flex-start", gap: 8 }}>
            {NEXT_STATUS[visit.status] && (
              <button onClick={() => advanceStatus(visit)} disabled={busyId === visit.id}>
                {busyId === visit.id ? "Saving…" : NEXT_LABEL[visit.status]}
              </button>
            )}
            {(visit.status === "requested" || visit.status === "confirmed") && (
              <button className="secondary" onClick={() => cancelVisit(visit)} disabled={busyId === visit.id}>
                Cancel
              </button>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
