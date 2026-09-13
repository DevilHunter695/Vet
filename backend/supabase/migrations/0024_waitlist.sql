-- C10: waitlist for uncovered clusters. An address with no cluster_area
-- match (see match_cluster() in 0004_addresses.sql) currently dead-ends —
-- this lets a customer join a waitlist for that area and lets the app show
-- "N neighbours already waiting" without exposing who they are.

create table waitlist_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  address_id uuid references addresses(id) on delete set null,
  latitude double precision not null,
  longitude double precision not null,
  area_label text, -- best-effort human label ("near HSR Layout"), not a served cluster_area
  joined_at timestamptz not null default now(),
  -- One active waitlist entry per user per address avoids double-counting the
  -- same household tapping "join" repeatedly (C10 dedup).
  unique (user_id, address_id)
);

create index waitlist_entries_location_idx on waitlist_entries(latitude, longitude);

alter table waitlist_entries enable row level security;

-- Owner-only read/insert of the raw rows — the public-facing count goes
-- through the RPC below instead, so nobody's presence on the waitlist (or
-- location) is individually exposed to other users.
create policy "waitlist_entries owner read" on waitlist_entries for select
  using (user_id = auth.uid() or is_admin());

create policy "waitlist_entries owner insert" on waitlist_entries for insert
  with check (user_id = auth.uid());

create policy "waitlist_entries owner delete" on waitlist_entries for delete
  using (user_id = auth.uid() or is_admin());

-- Public "N neighbours already waiting" count — same haversine approximation
-- as match_cluster() in 0004_addresses.sql, deliberately coarse (a real
-- deployment upgrades both to PostGIS ST_DWithin together). SECURITY DEFINER
-- so an unauthenticated/other-user caller can get a count without the
-- underlying row-level policy (owner-only) blocking the aggregate.
create or replace function waitlist_count_near(p_lat double precision, p_lng double precision, radius_km double precision default 3.0)
returns bigint
language sql
security definer
set search_path = public
stable as $$
  select count(*) from waitlist_entries w
  where (
    6371 * acos(
      least(1.0, cos(radians(p_lat)) * cos(radians(w.latitude)) * cos(radians(w.longitude) - radians(p_lng))
        + sin(radians(p_lat)) * sin(radians(w.latitude)))
    )
  ) < radius_km;
$$;

revoke all on function waitlist_count_near(double precision, double precision, double precision) from public;
grant execute on function waitlist_count_near(double precision, double precision, double precision) to authenticated, anon;
