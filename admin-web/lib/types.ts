export interface Vet {
  id: string;
  auth_id: string | null;
  name: string;
  license_number: string;
  verification_status: "pending" | "verified" | "rejected";
  rating: number;
  review_count: number;
  created_at: string;
}

export interface Circuit {
  id: string;
  vet_id: string;
  cluster_area: string;
  created_at: string;
  vets?: { name: string };
  schedule_slots?: { id: string }[];
}

export interface PayoutRow {
  id: string;
  vet_id: string;
  period_start: string;
  period_end: string;
  amount_minor_units: number;
  status: "pending" | "paid" | "failed";
  gateway_reference: string | null;
  vets?: { name: string };
}

export interface VetUnpaidBalance {
  vet_id: string;
  vet_name: string;
  unpaid_minor_units: number;
}

export const VISIT_STATUSES = [
  "requested", "confirmed", "assigned", "en_route", "arrived", "in_progress",
  "completed", "cancelled_by_user", "cancelled_by_vet", "no_show_user", "no_show_vet",
  "disputed", "resolved",
] as const;

export type VisitStatus = (typeof VISIT_STATUSES)[number];

export interface VisitRow {
  id: string;
  user_id: string;
  vet_id: string;
  status: VisitStatus;
  scheduled_at: string;
  completed_at: string | null;
  payment_id: string | null;
  vets?: { name: string };
  payments?: { id: string; amount_minor_units: number; status: string } | null;
}

export interface FeatureFlag {
  name: string;
  enabled: boolean;
  description: string | null;
}

export interface ReviewRow {
  id: string;
  visit_id: string;
  vet_id: string;
  user_id: string;
  rating: number;
  comment: string | null;
  created_at: string;
  vets?: { name: string };
}
