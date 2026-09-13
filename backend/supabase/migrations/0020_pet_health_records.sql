-- Plan §3 B (pet detail, weight/vitals, vaccinations, archive) and §3 K
-- (prescription history). B4 is flagged P0 ("the single best repeat-purchase
-- driver in pet care") so the vaccinations table gets extended in place
-- rather than duplicated — 0019 already created a minimal version of it for
-- the N3 lifecycle-notification job.

alter table pets
  add column sex text check (sex in ('male', 'female', 'unknown')),
  add column is_neutered boolean,
  add column weight_kg double precision,
  add column microchip_number text,
  add column allergies text,
  add column chronic_conditions text,
  -- B8: soft-delete, matching the DeletionRequest/anonymised_at pattern
  -- elsewhere — a pet's visit history must survive archiving, so this is a
  -- flag on the row, never a hard delete.
  add column archived_at timestamptz,
  add column archive_reason text check (archive_reason in ('deceased', 'rehomed', 'other'));

-- B3: weight/vitals history, one row per reading, so the client can chart a
-- trend rather than only ever showing the pet's current weight.
create table pet_weights (
  id uuid primary key default gen_random_uuid(),
  pet_id uuid not null references pets(id) on delete cascade,
  owner_id uuid not null references users(id) on delete cascade,
  weight_kg double precision not null,
  recorded_at timestamptz not null default now()
);

create index pet_weights_pet_id_idx on pet_weights(pet_id, recorded_at);

alter table pet_weights enable row level security;

create policy "pet weights all own" on pet_weights for all
  using (owner_id = auth.uid() or is_admin())
  with check (owner_id = auth.uid());

-- B4: 0019's vaccinations table had just enough to drive the reminder job —
-- add the fields the actual health-record UI (batch number, a link back to
-- the visit it was given at) needs, without touching that migration.
alter table vaccinations
  add column batch_number text,
  add column visit_id uuid references visits(id) on delete set null;

-- K2: prescription history, one row per medication issued at a visit.
create table prescriptions (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  pet_id uuid not null references pets(id) on delete cascade,
  owner_id uuid not null references users(id) on delete cascade,
  prescribed_by_vet_id uuid not null references vets(id),
  medication_name text not null,
  dosage text not null,
  instructions text,
  issued_at timestamptz not null default now()
);

create index prescriptions_pet_id_idx on prescriptions(pet_id, issued_at);

alter table prescriptions enable row level security;

create policy "prescriptions read own" on prescriptions for select
  using (owner_id = auth.uid() or is_admin());

-- No client insert/update: a prescription is written by the vet/ops side of
-- the visit-completion flow, never authored by the pet owner themselves.
