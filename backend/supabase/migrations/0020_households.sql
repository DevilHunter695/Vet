-- A9: household sharing — invite a spouse/family member to see and book for
-- the same pets. Modeling decision (mirrored in Domain/Models/HouseholdModels.swift):
-- pets keep `owner_id` as their identity (no change to ownership/billing), and
-- household membership only grants *visibility* via an additional RLS policy
-- below — simpler and safer than reassigning pet ownership to a household.

create table households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  invited_phone text, -- set until the invitee's user row exists / accepts
  joined_at timestamptz not null default now(),
  unique (household_id, user_id)
);

create index household_members_user_id_idx on household_members(user_id);
create index household_members_household_id_idx on household_members(household_id);

alter table households enable row level security;
alter table household_members enable row level security;

-- A member (any role) can read the household and its own member row; only
-- the owner can create/remove — matches the owner-vs-member split used by
-- `is_admin()` elsewhere in this schema rather than inventing a new pattern.
create policy "households select member" on households for select
  using (
    owner_id = auth.uid()
    or exists (select 1 from household_members hm where hm.household_id = households.id and hm.user_id = auth.uid())
  );

create policy "households insert self" on households for insert
  with check (owner_id = auth.uid());

create policy "households owner update" on households for update
  using (owner_id = auth.uid());

create policy "households owner delete" on households for delete
  using (owner_id = auth.uid());

-- A member can see every other member's basic membership row (name/role),
-- so the household roster renders — but only the owner may insert (invite)
-- or delete (remove/leave-on-behalf-of) rows.
create policy "household_members select fellow member" on household_members for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = household_members.household_id and hm.user_id = auth.uid()
    )
  );

create policy "household_members owner insert" on household_members for insert
  with check (
    exists (select 1 from households h where h.id = household_id and h.owner_id = auth.uid())
  );

-- A member may delete their own row (leave); the owner may delete anyone's
-- (remove) — both expressed as one policy since the row-level condition
-- covers each case.
create policy "household_members leave or owner remove" on household_members for delete
  using (
    user_id = auth.uid()
    or exists (select 1 from households h where h.id = household_id and h.owner_id = auth.uid())
  );

-- Visibility grant (not an ownership change, see comment above): any pet
-- whose owner shares a household with the viewer becomes readable to them,
-- as an *additional* permissive policy alongside "pets all own" (0001_init.sql)
-- — Postgres OR's permissive policies together, so this only ever widens read
-- access, never narrows the existing owner-write policy.
create policy "pets household select" on pets for select
  using (
    exists (
      select 1 from household_members mine
      join household_members theirs on theirs.household_id = mine.household_id
      where mine.user_id = auth.uid() and theirs.user_id = pets.owner_id
    )
  );
