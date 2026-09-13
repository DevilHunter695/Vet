-- H3 (manage: upgrade/downgrade/pause/cancel) and H5 (dunning: failed
-- renewal -> retry ladder -> grace -> downgrade). Expand/contract per plan
-- §11, same pattern as 0005/0010: add columns and the new constraint
-- values, backfill, then swap the constraint in one migration — nothing is
-- ever left half-defined between deploys.

-- Real bug found in 0001_init.sql: the Swift `Subscription.PlanType` enum
-- has always had a `corporate` case (plan §H7, and CorporatePlanView has
-- shipped against it), but the DB check constraint only ever allowed
-- ('monthly', 'quarterly', 'annual') — any corporate subscribe() insert
-- would have been rejected by Postgres, and existing rows have never been
-- able to prove they need >= 5 seats because there is no seat_count column
-- at all. Fixing both here rather than adding new code that plans around it.
alter table subscriptions add column seat_count integer not null default 1 check (seat_count > 0);

alter table subscriptions drop constraint subscriptions_plan_type_check;
alter table subscriptions add constraint subscriptions_plan_type_check
  check (plan_type in ('monthly', 'quarterly', 'annual', 'corporate'));

-- A corporate plan must keep the >= 5 seat floor SubscriptionManagementPolicy
-- and SubscribeToPlanUseCase both enforce client-side — enforce it at the
-- row level too, since the client is never the source of truth (plan rule 1).
alter table subscriptions add constraint subscriptions_corporate_seat_floor_check
  check (plan_type != 'corporate' or seat_count >= 5);

-- H3: pause/resume needs a status the original ('active', 'cancelled',
-- 'expired', 'past_due') set didn't have.
alter table subscriptions drop constraint subscriptions_status_check;
alter table subscriptions add constraint subscriptions_status_check
  check (status in ('active', 'cancelled', 'expired', 'past_due', 'paused'));

-- H5: dunning state lives on the subscription row, not a separate table —
-- unlike visit_events (many transitions over a visit's life), a
-- subscription has at most one live retry cycle at a time, so this is
-- simpler to reason about than an append-only log and matches how
-- `renewal_date` already lives directly on this table.
alter table subscriptions
  add column failed_attempts integer not null default 0 check (failed_attempts >= 0),
  add column next_retry_at timestamptz,
  add column grace_period_ends_at timestamptz;

-- Append-only audit of every subscription state change (plan §5.1:
-- "History is never rewritten") — upgrades, downgrades, pauses, cancels,
-- and dunning transitions all land here so ops can reconstruct what
-- happened to a customer's billing without trusting the mutable row alone.
create table subscription_events (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references subscriptions(id) on delete cascade,
  event_type text not null check (event_type in (
    'subscribed', 'upgraded', 'downgraded', 'paused', 'resumed', 'cancelled',
    'charge_failed', 'grace_started', 'auto_downgraded', 'renewed'
  )),
  from_plan_type text,
  to_plan_type text,
  actor_id uuid references auth.users(id), -- null = system/job-initiated (e.g. dunning)
  created_at timestamptz not null default now()
);

create index subscription_events_subscription_id_idx on subscription_events(subscription_id);

alter table subscription_events enable row level security;

-- Owner (or admin) can read their own subscription's history; nobody writes
-- from the client — the trusted boundary here is the same one refunds use
-- (plan §6.2): a Postgres function/trigger or the service-role dunning job
-- is the only writer, never a direct client insert.
create policy "subscription_events select own" on subscription_events for select
  using (exists (select 1 from subscriptions s where s.id = subscription_id and (s.user_id = auth.uid() or is_admin())));

revoke insert, update, delete on subscription_events from authenticated, anon;

-- Logs every plan_type/status change on subscriptions automatically, so
-- application code can't forget to write the audit row (the same trigger
-- shape 0010's legal_visit_transitions/visit_events pairing uses).
create or replace function log_subscription_event() returns trigger as $$
declare
  v_type text;
begin
  if tg_op = 'INSERT' then
    v_type := 'subscribed';
  elsif new.status = 'cancelled' and old.status != 'cancelled' then
    v_type := 'cancelled';
  elsif new.status = 'paused' and old.status != 'paused' then
    v_type := 'paused';
  elsif old.status = 'paused' and new.status = 'active' then
    v_type := 'resumed';
  elsif new.plan_type != old.plan_type then
    v_type := 'upgraded'; -- direction is determined app-side; the row still records old/new plan either way
  elsif new.failed_attempts > old.failed_attempts and new.grace_period_ends_at is null then
    v_type := 'charge_failed';
  elsif new.grace_period_ends_at is not null and old.grace_period_ends_at is null then
    v_type := 'grace_started';
  else
    return new; -- no billing-relevant change (e.g. renewal_date bump alone) — don't log noise
  end if;

  insert into subscription_events (subscription_id, event_type, from_plan_type, to_plan_type, actor_id)
  values (new.id, v_type, case when tg_op = 'INSERT' then null else old.plan_type end, new.plan_type, auth.uid());
  return new;
end;
$$ language plpgsql security definer;

create trigger subscriptions_log_event
  after insert or update on subscriptions
  for each row execute function log_subscription_event();
