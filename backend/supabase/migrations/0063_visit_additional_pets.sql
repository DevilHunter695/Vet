-- D6: "multi-pet in one visit". The cart has always let a line carry several
-- pets, and `PricingEngine` has always charged an additional-pet fee for each
-- one beyond the first — but `visits` has exactly one `pet_id`, so the booking
-- recorded a single pet. The customer paid for two pets and got a visit that
-- said one. This closes that on the database side.
--
-- Additive, like 0062: a new nullable column plus a replacement `book_visit()`
-- that accepts the companions. `pet_id` keeps its meaning as the primary pet,
-- which is also what the pricing engine prices against, so nothing that reads
-- `pet_id` today changes behaviour and no existing row needs backfilling.
--
-- Why a uuid[] column rather than a `visit_pets` join table: the companions
-- are never queried independently of their visit, never carry per-pet
-- attributes, and are written once at booking time. A join table would buy
-- referential integrity at the cost of a second write inside the booking
-- transaction and a join on every visit read. The trade is deliberate, and
-- `validate_visit_pets` below recovers most of the integrity a foreign key
-- would have given.

alter table visits add column additional_pet_ids uuid[] not null default '{}';

comment on column visits.additional_pet_ids is
  'D6: the other pets seen on this visit. pet_id remains the primary pet. Never contains pet_id itself, and every element must belong to the visit''s owner (enforced by validate_visit_pets).';

-- A uuid[] cannot carry a foreign key, so the two invariants that matter are
-- enforced by trigger instead:
--
--   1. A pet listed twice (or listed as both primary and companion) would be
--      charged twice by the pricing engine and read as a data error.
--   2. A visit must never reference someone else's pet. Without this, the
--      array is a hole straight through the RLS that protects `pets`, since
--      nothing else would check ownership of the ids inside it.
create or replace function validate_visit_pets() returns trigger language plpgsql as $$
declare
  v_owner uuid;
  v_foreign_count integer;
begin
  if new.additional_pet_ids is null or array_length(new.additional_pet_ids, 1) is null then
    return new;
  end if;

  if new.pet_id = any(new.additional_pet_ids) then
    raise exception 'VISIT_PET_DUPLICATED' using errcode = 'P0001';
  end if;

  if array_length(new.additional_pet_ids, 1)
     <> (select count(distinct id) from unnest(new.additional_pet_ids) as id) then
    raise exception 'VISIT_PET_DUPLICATED' using errcode = 'P0001';
  end if;

  -- Every companion must belong to whoever owns the primary pet.
  select owner_id into v_owner from pets where id = new.pet_id;

  select count(*) into v_foreign_count
    from unnest(new.additional_pet_ids) as companion_id
    where not exists (
      select 1 from pets where pets.id = companion_id and pets.owner_id = v_owner
    );

  if v_foreign_count > 0 then
    raise exception 'VISIT_PET_NOT_OWNED' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger visits_validate_pets
  before insert or update of pet_id, additional_pet_ids on visits
  for each row execute function validate_visit_pets();

-- ---------------------------------------------------------------------------
-- book_visit(): identical to 0062's version except that it accepts and stores
-- the companion pets. `p_additional_pet_ids` is text, comma-separated, because
-- every other parameter the client sends is text and PostgREST's rpc() maps
-- them that way — the client already sends this parameter (see
-- SupabaseVisitRepository.createVisit), it simply had nowhere to land.
--
-- It defaults to null, so every existing caller — including a client build
-- older than this migration — keeps working unchanged and books a single pet.
-- ---------------------------------------------------------------------------
create or replace function book_visit(
  p_pet_id uuid, p_vet_id uuid, p_circuit_id uuid, p_slot_id uuid,
  p_scheduled_at timestamptz, p_idempotency_key text,
  p_service_id uuid default null, p_variant_id uuid default null,
  p_package_redemption_id uuid default null,
  p_additional_pet_ids text default null
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

  insert into visits (user_id, pet_id, additional_pet_ids, vet_id, circuit_id, status, scheduled_at, service_id, variant_id, package_redemption_id)
    values (auth.uid(), p_pet_id, v_additional_pets, p_vet_id, p_circuit_id, 'requested', p_scheduled_at, p_service_id, p_variant_id, p_package_redemption_id)
    returning * into v_visit;

  update schedule_slots set booked_count = booked_count + 1 where id = p_slot_id;

  if p_package_redemption_id is not null then
    update package_redemptions set used_count = used_count + 1 where id = p_package_redemption_id;
  end if;

  insert into idempotency_keys (key, visit_id) values (p_idempotency_key, v_visit.id);

  return v_visit;
end;
$$;
