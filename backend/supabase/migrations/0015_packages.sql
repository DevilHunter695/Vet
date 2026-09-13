-- D4: packages/bundles ("Puppy first-year: 4 visits + 3 vaccines"), priced
-- and browsed the same way services are (§3 D). Buying a package is a
-- checkout-time stub — it expands into individual cart_items, one per
-- included service occurrence — rather than a redeemable entitlement;
-- full redemption tracking ("3 of 4 visits used") is a later migration
-- (see Appendix F gap list).

create table packages (
  id uuid primary key default gen_random_uuid(),
  vertical text not null default 'vet' check (vertical in ('vet', 'elder_care', 'physio')),
  name text not null,
  description text not null,
  price_minor_units integer not null check (price_minor_units >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table package_items (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references packages(id) on delete cascade,
  service_id uuid not null references services(id) on delete restrict,
  quantity integer not null check (quantity > 0)
);

create index package_items_package_id_idx on package_items(package_id);

-- ---------------------------------------------------------------------------
-- Row Level Security: mirrors 0003_catalog.sql exactly — public read (browse
-- before sign-in), ops-only write (D7: catalog managed from ops console).
-- ---------------------------------------------------------------------------
alter table packages enable row level security;
alter table package_items enable row level security;

create policy "packages public read" on packages for select using (is_active or is_admin());
create policy "packages admin write" on packages for all using (is_admin()) with check (is_admin());

create policy "package_items public read" on package_items for select using (
  exists (select 1 from packages p where p.id = package_id and (p.is_active or is_admin()))
);
create policy "package_items admin write" on package_items for all using (is_admin()) with check (is_admin());
