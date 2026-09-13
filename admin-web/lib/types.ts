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
