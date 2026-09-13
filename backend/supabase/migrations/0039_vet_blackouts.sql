-- F9: vet-declared leave/holiday windows. No slot on any of the vet's
-- circuits should be offered while one is active — enforced client-side in
-- `GetCircuitsUseCase` today (see TECHNICAL_PLAN.md's F9 row for the known
-- gap: there's no vet-facing management UI in this app yet, so rows here
-- are written by whatever vet-side surface eventually exists, or directly).

create table vet_blackouts (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references vets(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text,
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);

create index vet_blackouts_vet_id_idx on vet_blackouts(vet_id);

alter table vet_blackouts enable row level security;

-- The vet manages their own blackout rows (mirrors "vets update own" in
-- 0001_init.sql's is_vet() pattern). Any signed-in customer can read every
-- row — the table has no customer-identifying data, and the whole point is
-- that availability filtering needs to see every vet's blackouts, not just
-- one vet's own.
create policy "vet_blackouts select all" on vet_blackouts for select
  using (true);

create policy "vet_blackouts manage own" on vet_blackouts for insert
  with check (is_vet(vet_id) or is_admin());

create policy "vet_blackouts update own" on vet_blackouts for update
  using (is_vet(vet_id) or is_admin());

create policy "vet_blackouts delete own" on vet_blackouts for delete
  using (is_vet(vet_id) or is_admin());
