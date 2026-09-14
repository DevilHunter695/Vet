-- I7: the vet's in-visit checklist becomes the customer's record once the
-- visit completes. Filling it out is inherently a vet-side action — this
-- app has no vet-mode surface at all (matches F9/I5's existing scope
-- boundary) — so, like lab_test_reports (0044), there is deliberately no
-- client insert/update policy here: the client only ever reads.

create table visit_checklist_items (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  label text not null,
  is_completed boolean not null default false,
  note text,
  completed_at timestamptz,
  sort_order int not null default 0
);

alter table visit_checklist_items enable row level security;

create policy "visit_checklist_items select own" on visit_checklist_items for select
  using (
    exists (select 1 from visits v where v.id = visit_checklist_items.visit_id and v.user_id = auth.uid())
  );

-- No insert/update/delete policy for any client role: items are written
-- ops/vet-side only (service-role), never by this app.

create index visit_checklist_items_visit_id_idx on visit_checklist_items (visit_id, sort_order);
