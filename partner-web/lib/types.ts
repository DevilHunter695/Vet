// Mirrors VetCircuit/Domain/Models/Models.swift — kept in sync by hand since
// this is a separate app talking to the same Postgres schema.

// Appendix B's 8-state machine (up from the original 5) — kept in sync with
// VetCircuit/Domain/Models/Models.swift and the legal_visit_transitions
// table in backend/supabase/migrations/0010_visit_otp_and_consent.sql.
export type VisitStatus =
  | "requested" | "confirmed" | "assigned" | "en_route" | "arrived" | "in_progress"
  | "completed" | "cancelled_by_user" | "cancelled_by_vet" | "no_show_user" | "no_show_vet"
  | "disputed" | "resolved";

export interface ScheduleSlot {
  id: string;
  circuit_id: string;
  day_of_week: number;
  start_time: string;
  end_time: string;
  is_available: boolean;
}

export interface Circuit {
  id: string;
  vet_id: string;
  cluster_area: string;
  schedule_slots?: ScheduleSlot[];
}

export interface Visit {
  id: string;
  user_id: string;
  pet_id: string;
  vet_id: string;
  circuit_id: string;
  status: VisitStatus;
  scheduled_at: string;
  completed_at: string | null;
  notes: string | null;
  payment_id: string | null;
  pets?: { name: string; species: string };
}

export interface VetLedgerEntry {
  id: string;
  vet_id: string;
  visit_id: string | null;
  amount_minor_units: number;
  description: string;
  payout_id: string | null;
  created_at: string;
}

export interface Payout {
  id: string;
  vet_id: string;
  period_start: string;
  period_end: string;
  amount_minor_units: number;
  status: "pending" | "paid" | "failed";
  gateway_reference: string | null;
  paid_at: string | null;
}

export interface Vet {
  id: string;
  auth_id: string;
  name: string;
  license_number: string;
  verification_status: "pending" | "verified" | "rejected";
  rating: number;
  review_count: number;
}
