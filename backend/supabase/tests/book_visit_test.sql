-- Behavioural tests for book_visit(), the one transaction every booking goes
-- through. Run against a scratch database that has had every migration
-- applied (see scripts/test-migrations.sh, which sets up the Supabase shim
-- this needs: an `auth` schema and an `auth.uid()` pinned to the caller).
--
-- These exist because the Swift side is covered by 462 unit tests and the SQL
-- side was covered by nothing at all. The address and reason columns, and the
-- ownership check below, were reasoned about and reviewed but never executed
-- until this file.

\set ON_ERROR_STOP on
\set CALLER  '00000000-0000-0000-0000-000000000001'
\set OTHER   '00000000-0000-0000-0000-000000000002'
\set PET     '00000000-0000-0000-0000-0000000000a1'
\set VET     '00000000-0000-0000-0000-0000000000b1'
\set CIRCUIT '00000000-0000-0000-0000-0000000000c1'
\set SLOT    '00000000-0000-0000-0000-0000000000d1'
\set MINE    '00000000-0000-0000-0000-0000000000e1'
\set THEIRS  '00000000-0000-0000-0000-0000000000e2'

begin;

insert into auth.users(id) values (:'CALLER'), (:'OTHER');
insert into users(id, name, email) values (:'CALLER','Caller','caller@example.test'),
                                          (:'OTHER','Stranger','other@example.test');
insert into pets(id, owner_id, name, species) values (:'PET', :'CALLER', 'Rex', 'dog');
insert into vets(id, name, license_number) values (:'VET', 'Dr Vet', 'LIC-TEST-1');
insert into circuits(id, vet_id, cluster_area) values (:'CIRCUIT', :'VET', 'Indiranagar');
insert into schedule_slots(id, circuit_id, day_of_week, start_time, end_time, capacity, booked_count)
  values (:'SLOT', :'CIRCUIT', 1, now() + interval '1 day', now() + interval '1 day 1 hour', 3, 0);
insert into addresses(id, owner_id, label, line1, latitude, longitude, cluster_area)
  values (:'MINE', :'CALLER', 'Home', '12 Main St', 12.9, 77.6, 'Indiranagar');
insert into addresses(id, owner_id, label, line1, latitude, longitude)
  values (:'THEIRS', :'OTHER', 'Their flat', '99 Other Rd', 12.8, 77.5);

do $$
declare
  v record;
  v_first_id uuid;
  v_replay_id uuid;
  caller_address constant uuid := '00000000-0000-0000-0000-0000000000e1';
  other_address  constant uuid := '00000000-0000-0000-0000-0000000000e2';
  pet     constant uuid := '00000000-0000-0000-0000-0000000000a1';
  vet     constant uuid := '00000000-0000-0000-0000-0000000000b1';
  circuit constant uuid := '00000000-0000-0000-0000-0000000000c1';
  slot    constant uuid := '00000000-0000-0000-0000-0000000000d1';
begin
  -- 1. The address and the reason are actually stored, and the reason is
  --    trimmed the way the client trims it.
  select * into v from book_visit(pet, vet, circuit, slot, now() + interval '1 day',
    'test-key-1', null, null, null, null, caller_address, '  not eating since yesterday  ');
  assert v.address_id = caller_address, 'address_id was not stored';
  assert v.reason = 'not eating since yesterday', format('reason not trimmed: %L', v.reason);
  v_first_id := v.id;

  -- 2. An address belonging to somebody else is refused. book_visit() is
  --    security definer, so RLS on `addresses` does not apply inside it and
  --    this check is the only thing standing between a stranger's doorstep
  --    and a dispatched vet.
  begin
    perform book_visit(pet, vet, circuit, slot, now() + interval '1 day',
      'test-key-2', null, null, null, null, other_address, null);
    assert false, 'booking accepted an address the caller does not own';
  exception when sqlstate 'P0001' then
    assert sqlerrm = 'ADDRESS_NOT_OWNED', format('wrong error: %L', sqlerrm);
  end;

  -- 3. A field somebody tabbed through must not land as a row of spaces the
  --    vet then reads as a complaint.
  select * into v from book_visit(pet, vet, circuit, slot, now() + interval '1 day',
    'test-key-3', null, null, null, null, null, '    ');
  assert v.reason is null, format('whitespace reason stored as %L', v.reason);

  -- 4. Both are optional: a booking without either is still a booking.
  select * into v from book_visit(pet, vet, circuit, slot, now() + interval '1 day',
    'test-key-4', null, null, null, null, null, null);
  assert v.address_id is null and v.reason is null, 'nulls were not preserved';

  -- 5. Adding parameters must not have broken idempotency — a retried tap
  --    returns the original visit rather than booking a second one.
  select id into v_replay_id from book_visit(pet, vet, circuit, slot,
    now() + interval '1 day', 'test-key-1', null, null, null, null, null, null);
  assert v_replay_id = v_first_id, 'replaying an idempotency key created a new visit';

  -- 6. Nor capacity. Three distinct keys filled a capacity-3 slot above; the
  --    fourth must be refused.
  begin
    perform book_visit(pet, vet, circuit, slot, now() + interval '1 day',
      'test-key-5', null, null, null, null, null, null);
    assert false, 'a full slot accepted a fourth booking';
  exception when sqlstate 'P0001' then
    assert sqlerrm = 'SLOT_FULL', format('wrong error: %L', sqlerrm);
  end;

  raise notice 'book_visit: all 6 checks passed';
end $$;

-- 7. Exactly one book_visit() exists. Every migration that added a parameter
--    created a new overload rather than replacing the old one, and PostgREST
--    resolves an rpc call onto whichever matches the keys the client sent --
--    so a surviving older overload silently drops the address, the package
--    redemption, or the companion pets.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where p.proname = 'book_visit' and ns.nspname = 'public';
  assert n = 1, format('expected exactly one book_visit(), found %s', n);
  raise notice 'book_visit: exactly one overload';
end $$;

rollback;
