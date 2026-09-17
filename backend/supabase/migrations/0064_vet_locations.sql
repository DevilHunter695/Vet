-- I4: live vet location during a visit.
--
-- `LiveTrackingRepository` had no table to read from, so it was the last
-- customer-facing repository still pinned to a mock even in a credentialed
-- build — and the mock walks a fake vet along a straight line, which in a
-- build someone believes is real is a map confidently showing a vet who does
-- not exist.
--
-- One row per visit, overwritten in place. A location history is not wanted
-- here: this drives a live map and an ETA, nothing reads yesterday's
-- breadcrumbs, and keeping every ping for every visit is a lot of rows for a
-- feature that only ever asks "where are they now".

create table vet_locations (
  visit_id uuid primary key references visits(id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  eta_minutes integer check (eta_minutes >= 0),
  updated_at timestamptz not null default now()
);

alter table vet_locations enable row level security;

-- The customer on the visit can read it; nobody but the vet servicing it (or
-- ops) can write it. A client-writable location column would let anyone who
-- can see a visit move the pin, which is worse than having no map.
create policy "vet_locations select own visit" on vet_locations for select
  using (
    exists (
      select 1 from visits v
      where v.id = vet_locations.visit_id
        and (v.user_id = auth.uid() or is_vet(v.vet_id) or is_admin())
    )
  );

-- `is_vet(vet_id)` is the idiom 0001_init.sql established for "the vet this
-- row belongs to" — it checks `vets.auth_id`, which is the actual link to the
-- authenticated user. `vets` has no `user_id`; writing the join by hand got
-- that wrong, and the migration harness said so before this reached CI.
create policy "vet_locations write by servicing vet" on vet_locations for all
  using (
    exists (
      select 1 from visits v
      where v.id = vet_locations.visit_id and (is_vet(v.vet_id) or is_admin())
    )
  )
  with check (
    exists (
      select 1 from visits v
      where v.id = vet_locations.visit_id and (is_vet(v.vet_id) or is_admin())
    )
  );

-- Realtime delivers row changes to subscribers; without this the table is
-- readable but a client cannot be pushed updates from it.
alter publication supabase_realtime add table vet_locations;
