-- E7: slot hold (10 min) during checkout, auto-release. Prevents the
-- "slot taken while I was paying" disaster — a hold counts against a
-- slot's remaining capacity exactly like a confirmed booking would.

create table slot_holds (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references schedule_slots(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index slot_holds_slot_id_idx on slot_holds(slot_id) where expires_at > now();

alter table slot_holds enable row level security;

create policy "slot_holds all own" on slot_holds for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- Scheduled job (plan §6.5, "expire slot holds (1 min)") deletes expired
-- rows; a stale hold is otherwise harmless since every capacity check
-- filters on expires_at > now(), but pruning keeps the table small.
create or replace function expire_slot_holds() returns void as $$
  delete from slot_holds where expires_at <= now();
$$ language sql security definer;
