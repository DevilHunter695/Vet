-- Addresses (plan §A8) — a circuit is address-scoped; this is core inventory
-- logic, not account nicety. cluster_area is set by matching against a
-- served circuit's cluster on write, so discovery never re-derives it.

create table addresses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references users(id) on delete cascade,
  label text not null,
  line1 text not null,
  line2 text,
  landmark text,
  access_notes text,
  latitude double precision not null,
  longitude double precision not null,
  cluster_area text, -- null = not yet covered by any circuit; routes to waitlist (C10)
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create index addresses_owner_id_idx on addresses(owner_id);

-- Only one default address per owner.
create unique index addresses_one_default_per_owner
  on addresses(owner_id) where is_default;

alter table addresses enable row level security;

create policy "addresses all own" on addresses for all
  using (owner_id = auth.uid() or is_admin())
  with check (owner_id = auth.uid());

-- Geofence match: nearest served cluster within a coarse radius. A real
-- deployment upgrades this to PostGIS ST_DWithin on a cluster polygon column;
-- this haversine approximation is enough to unblock the client contract.
create or replace function match_cluster(p_lat double precision, p_lng double precision)
returns text language sql stable as $$
  select c.cluster_area from (
    select cluster_area, lat, lng from circuit_cluster_centers
  ) c
  where (
    6371 * acos(
      least(1.0, cos(radians(p_lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(p_lng))
        + sin(radians(p_lat)) * sin(radians(c.lat)))
    )
  ) < 3.0 -- km
  order by 1
  limit 1;
$$;

-- Cluster center lookup table — one row per served cluster_area, maintained
-- by ops as circuits are added (Q: circuit & slot editor).
create table circuit_cluster_centers (
  cluster_area text primary key,
  lat double precision not null,
  lng double precision not null
);

alter table circuit_cluster_centers enable row level security;
create policy "cluster centers public read" on circuit_cluster_centers for select using (true);
create policy "cluster centers admin write" on circuit_cluster_centers for all using (is_admin()) with check (is_admin());
