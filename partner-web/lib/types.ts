// Mirrors VetCircuit/Domain/Models/Models.swift — kept in sync by hand since
// this is a separate app talking to the same Postgres schema.

export type VisitStatus = "requested" | "confirmed" | "en_route" | "completed" | "cancelled";

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

export interface Vet {
  id: string;
  auth_id: string;
  name: string;
  license_number: string;
  verification_status: "pending" | "verified" | "rejected";
  rating: number;
  review_count: number;
}
