-- F2: capacity per slot (N stops per block), not boolean availability.
-- Expand/contract per plan §11: add the new columns and backfill from the
-- old boolean before anything drops it, so nothing between migrations is
-- ever left half-defined.

alter table schedule_slots
  add column capacity integer not null default 1 check (capacity > 0),
  add column booked_count integer not null default 0 check (booked_count >= 0);

-- Backfill: a previously-"available" slot gets real capacity headroom;
-- a previously-unavailable one is already full.
update schedule_slots set capacity = 5, booked_count = 0 where is_available;
update schedule_slots set capacity = 1, booked_count = 1 where not is_available;

-- NOTE (naming): this cannot be called `schedule_slots_capacity_check`.
-- Postgres auto-names the inline `check (capacity > 0)` above exactly that,
-- so declaring it here collides with "constraint ... already exists" and the
-- migration cannot apply. Found by actually running the migrations
-- (backend/test).
alter table schedule_slots
  add constraint schedule_slots_booked_within_capacity check (booked_count <= capacity);

-- is_available is now derived (booked_count < capacity), kept in sync by
-- trigger for any code path still reading the old column during rollout.
create or replace function sync_schedule_slot_availability() returns trigger as $$
begin
  new.is_available := new.booked_count < new.capacity;
  return new;
end;
$$ language plpgsql;

create trigger schedule_slots_sync_availability
  before insert or update of capacity, booked_count on schedule_slots
  for each row execute function sync_schedule_slot_availability();
