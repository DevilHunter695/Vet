-- Where the vet is actually supposed to go.
--
-- The whole product is a vet coming to your home, and until now a visit
-- recorded no address at all: `carts.address_id` existed (0007) and the app
-- always wrote null into it, and `visits` had no such column to begin with.
-- Dispatch therefore had nothing but the circuit's cluster area - a
-- neighbourhood, not a doorstep.
--
-- Nullable, because visits already in the table predate this and because a
-- booking made against a circuit the customer walks to has no address to
-- give. `on delete set null` for the same reason the cart uses it: deleting a
-- saved address must not delete the visit history that referenced it.
alter table visits
  add column address_id uuid references addresses(id) on delete set null;

comment on column visits.address_id is
  'The customer address this home visit is booked for. Null for legacy rows and for bookings made without a saved address.';

create index visits_address_id_idx on visits(address_id);

-- ---------------------------------------------------------------------------
-- book_visit(): 0063's version plus `p_address_id`, so the booking records
-- where the vet is going. Defaulted to null and appended last, so a client
-- build older than this migration keeps booking unchanged.
--
-- The ownership check is not optional here. The function is security definer,
-- so row-level security on `addresses` is bypassed inside it; without the
-- check, a caller could pass any address id at all and have a vet sent to
-- somebody else's home.
-- ---------------------------------------------------------------------------
create or replace function book_visit(
  p_pet_id uuid, p_vet_id uuid, p_circuit_id uuid, p_slot_id uuid,
  p_scheduled_at timestamptz, p_idempotency_key text,
  p_service_id uuid default null, p_variant_id uuid default null,
  p_package_redemption_id uuid default null,
  p_additional_pet_ids text default null,
  p_address_id uuid default null
) returns visits language plpgsql security definer as $$
declare
  v_visit visits;
  v_existing_visit_id uuid;
  v_capacity integer;
  v_booked_count integer;
  v_redemption_total integer;
  v_redemption_used integer;
  v_additional_pets uuid[] := '{}';
begin
  -- Same key already processed: return the original result, don't re-run.
  select visit_id into v_existing_visit_id from idempotency_keys where key = p_idempotency_key;
  if v_existing_visit_id is not null then
    select * into v_visit from visits where id = v_existing_visit_id;
    return v_visit;
  end if;

  -- Parsed before anything is locked: a malformed uuid should fail the call
  -- outright, not after a slot row is already held.
  if p_additional_pet_ids is not null and length(trim(p_additional_pet_ids)) > 0 then
    select array_agg(distinct trim(part)::uuid)
      into v_additional_pets
      from unnest(string_to_array(p_additional_pet_ids, ',')) as part
      where length(trim(part)) > 0;
    -- The primary pet appearing in its own companion list is a client bug,
    -- not a reason to reject the booking; drop it the way the client does.
    v_additional_pets := array_remove(coalesce(v_additional_pets, '{}'), p_pet_id);
  end if;

  -- Lock the slot row so a concurrent call can't read a stale booked_count.
  select capacity, booked_count into v_capacity, v_booked_count
    from schedule_slots where id = p_slot_id for update;

  if v_capacity is null then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- One visit occupies one slot however many pets it covers — a single
  -- home visit for two pets is one appointment for the vet, which is the
  -- whole point of D6 and why this is not multiplied by the pet count.
  if v_booked_count >= v_capacity then
    raise exception 'SLOT_FULL' using errcode = 'P0001';
  end if;

  -- D4: lock the redemption row too, so two concurrent bookings against the
  -- same "3 of 4 used" entitlement can't both read it as having a slot left.
  if p_package_redemption_id is not null then
    select total_count, used_count into v_redemption_total, v_redemption_used
      from package_redemptions where id = p_package_redemption_id and user_id = auth.uid()
      for update;

    if v_redemption_total is null then
      raise exception 'PACKAGE_REDEMPTION_NOT_FOUND' using errcode = 'P0002';
    end if;

    if v_redemption_used >= v_redemption_total then
      raise exception 'PACKAGE_REDEMPTION_EXHAUSTED' using errcode = 'P0001';
    end if;
  end if;

  -- An address that isn't the caller's own would hand a stranger's doorstep
  -- to a vet, so it is checked here rather than trusted from the client.
  -- This function is security definer, which means RLS on `addresses` does
  -- not protect it.
  if p_address_id is not null then
    perform 1 from addresses where id = p_address_id and owner_id = auth.uid();
    if not found then
      raise exception 'ADDRESS_NOT_OWNED' using errcode = 'P0001';
    end if;
  end if;

  insert into visits (user_id, pet_id, additional_pet_ids, vet_id, circuit_id, status, scheduled_at, service_id, variant_id, package_redemption_id, address_id)
    values (auth.uid(), p_pet_id, v_additional_pets, p_vet_id, p_circuit_id, 'requested', p_scheduled_at, p_service_id, p_variant_id, p_package_redemption_id, p_address_id)
    returning * into v_visit;

  update schedule_slots set booked_count = booked_count + 1 where id = p_slot_id;

  if p_package_redemption_id is not null then
    update package_redemptions set used_count = used_count + 1 where id = p_package_redemption_id;
  end if;

  insert into idempotency_keys (key, visit_id) values (p_idempotency_key, v_visit.id);

  return v_visit;
end;
$$;
