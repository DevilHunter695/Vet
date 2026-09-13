import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";
import RefundPanel from "@/components/RefundPanel";
import type { VisitRow } from "@/lib/types";

/// "Disputes" surfaces low-rated reviews for manual follow-up. There's no
/// dedicated disputes table yet — this is the cheapest signal that gets a
/// human looking at a bad visit without building a full ticketing system
/// before there's evidence it's needed.
///
/// Refund issuance lives on this page too (plan §Q) since a refund is
/// usually the resolution to a dispute — the button calls the issue-refund
/// Edge Function (backend/supabase/functions/issue-refund), never a direct
/// insert; `refunds` is select-only under RLS by design (migration 0009).
export default async function DisputesPage() {
  const { supabase } = await requireAdmin();
  const { data: reviews } = await supabase
    .from("reviews")
    .select("*, vets(name)")
    .lte("rating", 2)
    .order("created_at", { ascending: false });

  const { data: visits } = await supabase
    .from("visits")
    .select("*, vets(name), payments(id, amount_minor_units, status)")
    .in("status", ["completed", "cancelled_by_user", "cancelled_by_vet"])
    .not("payment_id", "is", null)
    .order("scheduled_at", { ascending: false })
    .limit(30);

  return (
    <div className="container">
      <h1>Disputes</h1>
      <NavTabs />

      <section style={{ marginBottom: 32 }}>
        <h2>Issue a refund</h2>
        <p className="muted">Recent completed or cancelled visits with a payment attached.</p>
        <RefundPanel visits={(visits ?? []) as VisitRow[]} />
      </section>

      <h2>Flagged reviews</h2>
      <p className="muted">Visits rated 2 stars or below — worth a manual look.</p>
      {(reviews ?? []).length === 0 ? (
        <p className="muted">No flagged reviews right now.</p>
      ) : (
        reviews!.map((review) => (
          <div key={review.id} className="card">
            <div className="row">
              <strong>{review.vets?.name ?? "Vet"}</strong>
              <span className="badge rejected">{review.rating}★</span>
            </div>
            {review.comment && <p style={{ marginTop: 8 }}>{review.comment}</p>}
            <p className="muted" style={{ marginTop: 6 }}>
              {new Date(review.created_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
            </p>
          </div>
        ))
      )}
    </div>
  );
}
