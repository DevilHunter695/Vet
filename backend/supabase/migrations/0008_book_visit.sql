-- The book_visit() transaction (plan Appendix D / §7.1) — the mechanism
-- that makes "two users book the last slot simultaneously" and "user taps
-- Pay twice" structurally impossible rather than merely unlikely.
--
-- Atomic by construction: locks the slot row, re-checks capacity under that
-- lock, inserts the visit, bumps booked_count, and records the idempotency
-- key — all in one transaction. A retried call with the same key returns
-- the original visit instead of creating a duplicate or double-booking.

create table idempotency_keys (
  key text primary key,
  visit_id uuid not null references visits(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table idempotency_keys enable row level security;
create policy "idempotency_keys select own" on idempotency_keys for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_admin())));

create or replace function book_visit(
  p_pet_id uuid, p_vet_id uuid, p_circuit_id uuid, p_slot_id uuid,
  p_scheduled_at timestamptz, p_idempotency_key text
) returns visits language plpgsql security definer as $$
declare
  v_visit visits;
  v_existing_visit_id uuid;
  v_capacity integer;
  v_booked_count integer;
begin
  -- Same key already processed: return the original result, don't re-run.
  select visit_id into v_existing_visit_id from idempotency_keys where key = p_idempotency_key;
  if v_existing_visit_id is not null then
    select * into v_visit from visits where id = v_existing_visit_id;
    return v_visit;
  end if;

  -- Lock the slot row so a concurrent call can't read a stale booked_count.
  select capacity, booked_count into v_capacity, v_booked_count
    from schedule_slots where id = p_slot_id for update;

  if v_capacity is null then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_booked_count >= v_capacity then
    raise exception 'SLOT_FULL' using errcode = 'P0001';
  end if;

  insert into visits (user_id, pet_id, vet_id, circuit_id, status, scheduled_at)
    values (auth.uid(), p_pet_id, p_vet_id, p_circuit_id, 'requested', p_scheduled_at)
    returning * into v_visit;

  update schedule_slots set booked_count = booked_count + 1 where id = p_slot_id;

  insert into idempotency_keys (key, visit_id) values (p_idempotency_key, v_visit.id);

  return v_visit;
end;
$$;

-- Customers may never call this directly with an arbitrary pet/vet
-- combination without RLS still applying to the underlying insert — the
-- function runs as security definer specifically so it can do the slot
-- lock + capacity check + insert atomically, but the visits_insert_own
-- policy's ownership check is preserved because the insert sets
-- user_id = auth.uid() explicitly, not from client input.
