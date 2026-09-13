-- Service catalog (plan §D): services, variants, add-ons.
-- The largest structural gap from v1 — a Visit had no concept of *what* was
-- being bought. This table set is the source of truth the client browses and
-- the quote engine (§E, a later migration) will price against.

create table services (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in (
    'consult', 'vaccination', 'grooming', 'diagnostics', 'deworming', 'dental',
    'elder_care_visit', 'physio_session'
  )),
  name text not null,
  summary text not null,
  what_to_prepare text,
  eligible_species text[], -- null = all species
  requires_prescriber_vet boolean not null default false,
  min_pet_age_months integer,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table service_variants (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete cascade,
  name text not null,
  duration_minutes integer not null check (duration_minutes > 0),
  price_minor_units integer not null check (price_minor_units >= 0),
  additional_pet_price_minor_units integer not null default 0 check (additional_pet_price_minor_units >= 0),
  is_follow_up boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index service_variants_service_id_idx on service_variants(service_id);

create table addons (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete cascade,
  name text not null,
  price_minor_units integer not null check (price_minor_units >= 0),
  eligible_species text[],
  is_active boolean not null default true
);

create index addons_service_id_idx on addons(service_id);

-- ---------------------------------------------------------------------------
-- Row Level Security: the catalog is public read (customers browse before
-- signing in), and writes are ops-only — the app is never the source of
-- truth for what's sellable or at what price (plan §6.2 / Appendix F #7 Q).
-- ---------------------------------------------------------------------------
alter table services enable row level security;
alter table service_variants enable row level security;
alter table addons enable row level security;

create policy "services public read" on services for select using (is_active or is_admin());
create policy "services admin write" on services for all using (is_admin()) with check (is_admin());

create policy "service_variants public read" on service_variants for select using (is_active or is_admin());
create policy "service_variants admin write" on service_variants for all using (is_admin()) with check (is_admin());

create policy "addons public read" on addons for select using (is_active or is_admin());
create policy "addons admin write" on addons for all using (is_admin()) with check (is_admin());
