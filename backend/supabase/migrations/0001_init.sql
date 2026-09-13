-- VetCircuit initial schema
-- Mirrors the data model in the technical plan (Section 4.2) with Row Level
-- Security so a user can never read/write another user's data, even by
-- guessing an ID — this is the primary authorization boundary, not the client.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Users (pet owners). Row id == auth.users.id (Supabase Auth).
-- ---------------------------------------------------------------------------
create table users (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text unique,
  name text not null,
  email text,
  created_at timestamptz not null default now()
);

create table pets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references users(id) on delete cascade,
  name text not null,
  species text not null check (species in ('dog', 'cat', 'bird', 'other')),
  breed text,
  dob date
);

-- ---------------------------------------------------------------------------
-- Vets (partners) and circuits
-- ---------------------------------------------------------------------------
create table vets (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid unique references auth.users(id) on delete set null,
  name text not null,
  license_number text not null,
  license_number_encrypted bytea, -- pgcrypto-encrypted copy for sensitive display
  verification_status text not null default 'pending'
    check (verification_status in ('pending', 'verified', 'rejected')),
  rating numeric(2,1) not null default 0,
  review_count integer not null default 0,
  created_at timestamptz not null default now()
);

create table circuits (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references vets(id) on delete cascade,
  cluster_area text not null,
  vertical text not null default 'vet' check (vertical in ('vet', 'elder_care', 'physio')),
  created_at timestamptz not null default now()
);

create table schedule_slots (
  id uuid primary key default gen_random_uuid(),
  circuit_id uuid not null references circuits(id) on delete cascade,
  day_of_week integer not null check (day_of_week between 1 and 7),
  start_time timestamptz not null,
  end_time timestamptz not null,
  is_available boolean not null default true -- superseded by capacity/booked_count, see 0005_slot_capacity.sql
);

-- ---------------------------------------------------------------------------
-- Visits, subscriptions, payments
-- ---------------------------------------------------------------------------
create table visits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  pet_id uuid not null references pets(id) on delete cascade,
  vet_id uuid not null references vets(id) on delete restrict,
  circuit_id uuid not null references circuits(id) on delete restrict,
  status text not null default 'requested'
    check (status in ('requested', 'confirmed', 'en_route', 'completed', 'cancelled')),
  scheduled_at timestamptz not null,
  completed_at timestamptz,
  notes text,
  payment_id uuid,
  created_at timestamptz not null default now()
);

create index visits_user_id_idx on visits(user_id);
create index visits_vet_id_idx on visits(vet_id);

create table subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  plan_type text not null check (plan_type in ('monthly', 'quarterly', 'annual')),
  status text not null default 'active'
    check (status in ('active', 'cancelled', 'expired', 'past_due')),
  renewal_date timestamptz not null,
  created_at timestamptz not null default now()
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid references visits(id) on delete set null,
  subscription_id uuid references subscriptions(id) on delete set null,
  amount_minor_units integer not null check (amount_minor_units > 0),
  currency text not null default 'INR',
  status text not null default 'pending'
    check (status in ('pending', 'succeeded', 'failed', 'refunded')),
  gateway_reference text,
  created_at timestamptz not null default now(),
  constraint payments_target_check check (
    (visit_id is not null and subscription_id is null) or
    (visit_id is null and subscription_id is not null)
  )
);

alter table visits
  add constraint visits_payment_fk foreign key (payment_id) references payments(id) on delete set null;

create table chat_messages (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) <= 2000),
  sent_at timestamptz not null default now(),
  read_at timestamptz
);

create index chat_messages_visit_id_idx on chat_messages(visit_id);

create table reviews (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null unique references visits(id) on delete cascade,
  vet_id uuid not null references vets(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

create table loyalty_accounts (
  user_id uuid primary key references users(id) on delete cascade,
  points integer not null default 0 check (points >= 0),
  tier text not null default 'bronze' check (tier in ('bronze', 'silver', 'gold'))
);

create table referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references users(id) on delete cascade,
  code text not null,
  invited_phone text,
  status text not null default 'pending' check (status in ('pending', 'joined', 'rewarded')),
  reward_applied boolean not null default false,
  created_at timestamptz not null default now()
);

create index referrals_referrer_id_idx on referrals(referrer_id);

create table device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  token text not null,
  platform text not null default 'ios',
  created_at timestamptz not null default now(),
  unique (user_id, token)
);

-- ---------------------------------------------------------------------------
-- Trigger: keep vet rating/review_count in sync when a review is added
-- ---------------------------------------------------------------------------
create or replace function recalc_vet_rating() returns trigger as $$
begin
  update vets v
  set rating = coalesce((select avg(rating) from reviews where vet_id = v.id), 0),
      review_count = (select count(*) from reviews where vet_id = v.id)
  where v.id = new.vet_id;
  return new;
end;
$$ language plpgsql security definer;

create trigger reviews_after_insert
  after insert on reviews
  for each row execute function recalc_vet_rating();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table users enable row level security;
alter table pets enable row level security;
alter table vets enable row level security;
alter table circuits enable row level security;
alter table schedule_slots enable row level security;
alter table visits enable row level security;
alter table subscriptions enable row level security;
alter table payments enable row level security;
alter table chat_messages enable row level security;
alter table reviews enable row level security;
alter table device_tokens enable row level security;
alter table referrals enable row level security;
alter table loyalty_accounts enable row level security;

-- Helper: is the current auth user an admin?
create table admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table admins enable row level security;
create policy "admins read own row" on admins for select using (auth.uid() = user_id);

create or replace function is_admin() returns boolean as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$ language sql stable security definer;

create or replace function is_vet(target_vet_id uuid) returns boolean as $$
  select exists (select 1 from vets where id = target_vet_id and auth_id = auth.uid());
$$ language sql stable security definer;

-- users: a person can only read/update their own profile
create policy "users select own" on users for select using (auth.uid() = id or is_admin());
create policy "users update own" on users for update using (auth.uid() = id);
create policy "users insert own" on users for insert with check (auth.uid() = id);

-- pets: only the owner (or admin) can see/manage their pets
create policy "pets all own" on pets for all
  using (owner_id = auth.uid() or is_admin())
  with check (owner_id = auth.uid());

-- vets: public read (customers need to browse), only the vet themself or admin can update
create policy "vets public read" on vets for select using (true);
create policy "vets update own" on vets for update using (auth_id = auth.uid() or is_admin());
create policy "vets admin insert" on vets for insert with check (is_admin());

-- circuits + schedule_slots: public read, vet manages their own
create policy "circuits public read" on circuits for select using (true);
create policy "circuits vet write" on circuits for all
  using (is_vet(vet_id) or is_admin())
  with check (is_vet(vet_id) or is_admin());

create policy "schedule public read" on schedule_slots for select using (true);
create policy "schedule vet write" on schedule_slots for all
  using (is_vet((select vet_id from circuits where id = circuit_id)) or is_admin())
  with check (is_vet((select vet_id from circuits where id = circuit_id)) or is_admin());

-- visits: the owning customer or the assigned vet (or admin) can see it;
-- only the vet/admin may change status (customers can only create/cancel their own)
create policy "visits select own" on visits for select
  using (user_id = auth.uid() or is_vet(vet_id) or is_admin());

create policy "visits insert own" on visits for insert
  with check (user_id = auth.uid());

create policy "visits update by customer (cancel only)" on visits for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and status in ('cancelled'));

create policy "visits update by vet" on visits for update
  using (is_vet(vet_id) or is_admin());

-- subscriptions: owner only
create policy "subscriptions all own" on subscriptions for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- payments: visible to the visit/subscription owner or admin; writes are
-- server-side only (payment gateway webhook uses the service role key, which
-- bypasses RLS — never trust a client-reported payment success)
create policy "payments select own" on payments for select
  using (
    is_admin() or
    (visit_id is not null and exists (select 1 from visits v where v.id = visit_id and v.user_id = auth.uid())) or
    (subscription_id is not null and exists (select 1 from subscriptions s where s.id = subscription_id and s.user_id = auth.uid()))
  );

-- chat_messages: only participants in that visit (owner or assigned vet)
create policy "chat select participants" on chat_messages for select
  using (
    exists (
      select 1 from visits v
      where v.id = visit_id and (v.user_id = auth.uid() or is_vet(v.vet_id))
    )
  );

create policy "chat insert participants" on chat_messages for insert
  with check (
    sender_id = auth.uid() and
    exists (
      select 1 from visits v
      where v.id = visit_id and (v.user_id = auth.uid() or is_vet(v.vet_id))
    )
  );

-- reviews: owner writes once per visit, everyone can read (social proof)
create policy "reviews public read" on reviews for select using (true);
create policy "reviews insert own" on reviews for insert
  with check (
    user_id = auth.uid() and
    exists (select 1 from visits v where v.id = visit_id and v.user_id = auth.uid() and v.status = 'completed')
  );

-- device_tokens: owner only
create policy "device_tokens all own" on device_tokens for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- referrals: referrer manages their own invites
create policy "referrals all own" on referrals for all
  using (referrer_id = auth.uid() or is_admin())
  with check (referrer_id = auth.uid());

-- loyalty_accounts: owner reads their own; points are only ever awarded
-- server-side (a trigger or edge function using the service role key), never
-- directly writable by the client.
create policy "loyalty select own" on loyalty_accounts for select
  using (user_id = auth.uid() or is_admin());
