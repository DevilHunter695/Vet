-- D6's database-side behaviour, exercised with real rows.
--
-- 0063 adds `visits.additional_pet_ids` as a uuid[], which cannot carry a
-- foreign key — so a trigger enforces the two invariants that matter. Those
-- are the sort of thing that is easy to write and easy to get subtly wrong,
-- and "the migration applied" says nothing about whether they actually fire.
-- So: insert rows that should be accepted and rows that must be rejected, and
-- fail loudly if either does the opposite.
--
-- Runs inside a transaction that is rolled back, so it leaves nothing behind.

begin;

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into users (id, phone, name) values
  ('11111111-1111-1111-1111-111111111111', '+919845000001', 'Owner'),
  ('22222222-2222-2222-2222-222222222222', '+919845000002', 'Somebody else');
insert into pets (id, owner_id, name, species) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Miso', 'cat'),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Not yours', 'dog');
insert into vets (id, name, license_number) values
  ('cccccccc-0000-0000-0000-000000000001', 'Dr. Rohan Mehta', 'VCI-TEST-1');
insert into circuits (id, vet_id, cluster_area) values
  ('dddddddd-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'Koramangala 5th Block');

do $$
declare
  v_owner constant uuid := '11111111-1111-1111-1111-111111111111';
  v_bruno constant uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  v_miso  constant uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  v_theirs constant uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  v_vet   constant uuid := 'cccccccc-0000-0000-0000-000000000001';
  v_circuit constant uuid := 'dddddddd-0000-0000-0000-000000000001';
  v_stored uuid[];
begin
  -- 1. The point of the feature: two of your own pets on one visit.
  insert into visits (user_id, pet_id, additional_pet_ids, vet_id, circuit_id, status, scheduled_at)
    values (v_owner, v_bruno, array[v_miso], v_vet, v_circuit, 'requested', now())
    returning additional_pet_ids into v_stored;
  if v_stored <> array[v_miso] then
    raise exception 'D6 FAIL: companions were not stored (got %)', v_stored;
  end if;
  raise notice 'D6 ok: a two-pet visit is accepted and both pets are recorded';

  -- 2. The same pet twice would be charged twice by the pricing engine.
  begin
    insert into visits (user_id, pet_id, additional_pet_ids, vet_id, circuit_id, status, scheduled_at)
      values (v_owner, v_bruno, array[v_bruno], v_vet, v_circuit, 'requested', now());
    raise exception 'D6 FAIL: a duplicated pet was accepted';
  exception when sqlstate 'P0001' then
    if sqlerrm not like '%VISIT_PET_DUPLICATED%' then raise; end if;
    raise notice 'D6 ok: a duplicated pet is rejected';
  end;

  -- 3. The one that matters for security: a uuid[] carries no foreign key, so
  --    without this check the column is a hole through `pets`' RLS.
  begin
    insert into visits (user_id, pet_id, additional_pet_ids, vet_id, circuit_id, status, scheduled_at)
      values (v_owner, v_bruno, array[v_theirs], v_vet, v_circuit, 'requested', now());
    raise exception 'D6 FAIL: somebody else''s pet was accepted onto a visit';
  exception when sqlstate 'P0001' then
    if sqlerrm not like '%VISIT_PET_NOT_OWNED%' then raise; end if;
    raise notice 'D6 ok: another owner''s pet is rejected';
  end;

  -- 4. A single-pet visit must be written exactly as it always was.
  insert into visits (user_id, pet_id, vet_id, circuit_id, status, scheduled_at)
    values (v_owner, v_bruno, v_vet, v_circuit, 'requested', now())
    returning additional_pet_ids into v_stored;
  if coalesce(array_length(v_stored, 1), 0) <> 0 then
    raise exception 'D6 FAIL: a single-pet visit gained companions (%)', v_stored;
  end if;
  raise notice 'D6 ok: a single-pet visit is unchanged';
end $$;

rollback;
