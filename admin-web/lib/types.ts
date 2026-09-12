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
