import { requireAdmin } from "@/lib/guard";
import NavTabs from "@/components/NavTabs";

/// "Disputes" surfaces low-rated reviews for manual follow-up. There's no
/// dedicated disputes table yet — this is the cheapest signal that gets a
/// human looking at a bad visit without building a full ticketing system
/// before there's evidence it's needed.
export default async function DisputesPage() {
  const { supabase } = await requireAdmin();
  const { data: reviews } = await supabase
    .from("reviews")
    .select("*, vets(name)")
    .lte("rating", 2)
    .order("created_at", { ascending: false });

  return (
    <div className="container">
      <h1>Disputes</h1>
      <NavTabs />
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
