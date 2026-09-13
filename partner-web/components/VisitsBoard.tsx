"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Visit, VisitStatus } from "@/lib/types";

// Follows the legal_visit_transitions table exactly — one legal next step
// per state, so this board can never attempt a transition the DB trigger
// would reject (Appendix B's 8-state machine). `arrived -> in_progress` is
// deliberately absent here: Appendix B gates it on "vet (OTP ok)", so that
// one transition only happens through verify_visit_otp(), not a plain button.
const NEXT_STATUS: Partial<Record<VisitStatus, VisitStatus>> = {
  confirmed: "assigned",
  assigned: "en_route",
  en_route: "arrived",
  in_progress: "completed",
};

const NEXT_LABEL: Partial<Record<VisitStatus, string>> = {
  confirmed: "Assign myself",
  assigned: "Start route (en route)",
  en_route: "Mark arrived",
  in_progress: "Mark completed",
};

export default function VisitsBoard({ initialVisits }: { initialVisits: Visit[] }) {
  const supabase = createClient();
  const [visits, setVisits] = useState(initialVisits);
  const [notesDraft, setNotesDraft] = useState<Record<string, string>>({});
  const [otpDraft, setOtpDraft] = useState<Record<string, string>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  /// arrived -> in_progress only ever happens through this RPC (Appendix B:
  /// "arrived -> in_progress | vet (OTP ok)") — never a plain status update,
  /// so a vet can't fast-forward past the anti-fraud check.
  async function verifyOTP(visit: Visit) {
    const code = otpDraft[visit.id] ?? "";
    setBusyId(visit.id);
    setError(null);
    const { data: verified, error } = await supabase.rpc("verify_visit_otp", { p_visit_id: visit.id, p_code: code });
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    if (!verified) {
      setError("That code doesn't match — ask the customer to double-check it.");
      return;
    }
    setVisits((prev) => prev.map((v) => (v.id === visit.id ? { ...v, status: "in_progress" } : v)));
  }

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
    const { error } = await supabase.from("visits").update({ status: "cancelled_by_vet" }).eq("id", visit.id);
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    setVisits((prev) => prev.map((v) => (v.id === visit.id ? { ...v, status: "cancelled_by_vet" } : v)));
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

          {visit.status === "arrived" && (
            <div className="row" style={{ marginTop: 10, gap: 8 }}>
              <input
                placeholder="4-digit code from customer"
                maxLength={4}
                value={otpDraft[visit.id] ?? ""}
                onChange={(e) => setOtpDraft((prev) => ({ ...prev, [visit.id]: e.target.value }))}
              />
              <button onClick={() => verifyOTP(visit)} disabled={busyId === visit.id || (otpDraft[visit.id] ?? "").length !== 4}>
                {busyId === visit.id ? "Checking…" : "Verify & start visit"}
              </button>
            </div>
          )}

          {visit.status === "in_progress" && (
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
            {(visit.status === "requested" || visit.status === "confirmed" || visit.status === "assigned") && (
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
