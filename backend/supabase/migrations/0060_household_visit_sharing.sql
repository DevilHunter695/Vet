-- A9 follow-up: household sharing was previously visibility-only for
-- *pets* (0020_households.sql's "pets household select" policy) but never
-- extended to *bookings* — the plan row promises "see and book for the
-- same pets", and `visits` had no household-aware policy at all, so a
-- household member could see a fellow member's pet but not that pet's
-- upcoming or past visits. This closes that gap the same way: an
-- additional permissive policy, OR'd with the existing owner-only ones
-- (0001_init.sql "visits select own" / "visits update by customer"), so it
-- only ever widens access and never narrows what a booking's own customer
-- or vet can already do.

-- Any household member can see a visit booked for a pet owned by a fellow
-- member (including themselves) — mirrors "pets household select" exactly,
-- joined through `pets.owner_id` since `visits.user_id` is who *booked* the
-- visit, not who owns the pet it's for.
create policy "visits household select" on visits for select
  using (
    exists (
      select 1 from pets p
      join household_members mine on mine.user_id = auth.uid()
      join household_members theirs on theirs.household_id = mine.household_id and theirs.user_id = p.owner_id
      where p.id = visits.pet_id
    )
  );

-- A household member may cancel a booking made for a shared pet, not only
-- ones they personally booked — "book for the same pets" implies managing
-- those bookings too. Scoped to cancellation only, matching the narrower
-- "visits update by customer (cancel only)" policy's own shape rather than
-- granting household members the vet's full update surface.
create policy "visits household cancel" on visits for update
  using (
    exists (
      select 1 from pets p
      join household_members mine on mine.user_id = auth.uid()
      join household_members theirs on theirs.household_id = mine.household_id and theirs.user_id = p.owner_id
      where p.id = visits.pet_id
    )
  )
  with check (status = 'cancelled');
