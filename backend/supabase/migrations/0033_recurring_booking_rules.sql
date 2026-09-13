-- F5: recurring booking rules (monthly deworming, weekly physio). Owner-only
-- — a customer's own recurring plan is nobody else's business, same pattern
-- as pets/addresses (0001_init.sql). Actually spawning the next visit each
-- cycle is a scheduled-job concern, not part of this table's job.

create table recurring_booking_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  pet_id uuid not null references pets(id) on delete cascade,
  service_id uuid not null references services(id) on delete cascade,
  variant_id uuid not null references service_variants(id) on delete cascade,
  circuit_id uuid not null references circuits(id) on delete cascade,
  cadence text not null check (cadence in ('weekly', 'monthly')),
  next_occurrence_at timestamptz not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index recurring_booking_rules_user_id_idx on recurring_booking_rules(user_id);

alter table recurring_booking_rules enable row level security;

create policy "recurring_booking_rules all own" on recurring_booking_rules for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());
