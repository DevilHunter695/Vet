-- H7: corporate/RWA seat assignment — who fills each of a corporate
-- subscription's billed seats. `subscriptions.seat_count` stays the billed
-- quantity (and the money-side authority via SubscriptionManagementPolicy's
-- seat floor); this table is just the roster, mirroring household_members'
-- "invite by phone" shape (0020_households.sql).

create table corporate_seat_assignments (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references subscriptions(id) on delete cascade,
  assigned_phone text not null,
  assigned_user_id uuid references users(id) on delete set null,
  assigned_at timestamptz not null default now(),
  unique (subscription_id, assigned_phone)
);

alter table corporate_seat_assignments enable row level security;

-- Only the subscription's owner (the RWA/corporate admin who bought the
-- plan) may see or manage its roster.
create policy "corporate_seat_assignments select own" on corporate_seat_assignments for select
  using (
    exists (select 1 from subscriptions s where s.id = corporate_seat_assignments.subscription_id and s.user_id = auth.uid())
  );

create policy "corporate_seat_assignments insert own" on corporate_seat_assignments for insert
  with check (
    exists (
      select 1 from subscriptions s
      where s.id = corporate_seat_assignments.subscription_id and s.user_id = auth.uid() and s.plan_type = 'corporate'
    )
    -- The seat-count ceiling itself is enforced by the app layer today
    -- (SubscriptionManagementPolicy/CorporateSeatAssignmentRepository); a
    -- belt-and-suspenders DB-level check constraint is a reasonable follow-up
    -- but isn't required for RLS correctness here.
  );

create policy "corporate_seat_assignments delete own" on corporate_seat_assignments for delete
  using (
    exists (select 1 from subscriptions s where s.id = corporate_seat_assignments.subscription_id and s.user_id = auth.uid())
  );

create index corporate_seat_assignments_subscription_id_idx on corporate_seat_assignments (subscription_id);
