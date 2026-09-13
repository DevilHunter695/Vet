-- D5: per-vet service availability & pricing overrides — a vet can opt out
-- of a catalog service, or charge more/less than the catalog default,
-- without ops editing the shared catalog per vet. Public read since a
-- customer needs to see the effective price before booking; vet-write-own
-- via is_vet(vet_id), same pattern as circuits/schedule_slots (0001_init.sql).

create table vet_service_overrides (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references vets(id) on delete cascade,
  service_id uuid not null references services(id) on delete cascade,
  variant_id uuid references service_variants(id) on delete cascade,
  price_override_minor_units integer,
  is_offered boolean not null default true,
  created_at timestamptz not null default now(),
  unique (vet_id, service_id, variant_id)
);

create index vet_service_overrides_vet_id_idx on vet_service_overrides(vet_id);

alter table vet_service_overrides enable row level security;

create policy "vet_service_overrides public read" on vet_service_overrides for select using (true);

create policy "vet_service_overrides vet write" on vet_service_overrides for all
  using (is_vet(vet_id) or is_admin())
  with check (is_vet(vet_id) or is_admin());
