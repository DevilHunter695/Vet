-- K3: medication reminders — a household-shareable record so a spouse/family
-- member can also see and manage "give Bruno his 8am pill" the same way
-- household sharing already extends to pets (0020_households.sql), not just
-- the owning user.

create table medication_reminders (
  id uuid primary key default gen_random_uuid(),
  pet_id uuid not null references pets(id) on delete cascade,
  medication_name text not null,
  dosage text not null default '',
  times jsonb not null default '[]'::jsonb, -- [{"hour": 8, "minute": 0}, ...]
  start_date timestamptz not null,
  end_date timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);

create index medication_reminders_pet_id_idx on medication_reminders(pet_id);

alter table medication_reminders enable row level security;

-- Same shape as "pets household select" (0020_households.sql): the pet's
-- owner, or anyone sharing a household with the owner, can manage its
-- reminders — visibility/management follows the pet, not a separate grant.
create policy "medication_reminders manage via pet household" on medication_reminders for all
  using (
    exists (
      select 1 from pets p
      where p.id = medication_reminders.pet_id
      and (
        p.owner_id = auth.uid()
        or exists (
          select 1 from household_members mine
          join household_members theirs on theirs.household_id = mine.household_id
          where mine.user_id = auth.uid() and theirs.user_id = p.owner_id
        )
      )
    )
    or is_admin()
  )
  with check (
    exists (
      select 1 from pets p
      where p.id = medication_reminders.pet_id
      and (
        p.owner_id = auth.uid()
        or exists (
          select 1 from household_members mine
          join household_members theirs on theirs.household_id = mine.household_id
          where mine.user_id = auth.uid() and theirs.user_id = p.owner_id
        )
      )
    )
    or is_admin()
  );
