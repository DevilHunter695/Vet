-- H6: subscription credits consumed by bookings (entitlement engine).
-- One row per subscription, tracked separately from `subscriptions` itself
-- (0017_subscription_management.sql) because a credit balance resets on a
-- calendar-month boundary, independent of any billing-status transition —
-- see EntitlementPolicy in Domain/Models/Models.swift for the pure
-- credits-per-period rule this table's `consume_subscription_credit`
-- function mirrors server-side.

create table subscription_entitlements (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null unique references subscriptions(id) on delete cascade,
  credits_remaining integer not null default 0 check (credits_remaining >= 0),
  reset_at timestamptz not null default (now() + interval '1 month')
);

alter table subscription_entitlements enable row level security;

-- Owner reads their own entitlement (to show "1 credit left" in Profile);
-- no client update/insert policy at all — only the security-definer function
-- below (and, eventually, a signup edge function seeding the initial row)
-- may change a balance. Mirrors the "no client write path" shape of
-- `refunds`/`payouts` elsewhere in this schema.
create policy "subscription_entitlements select own" on subscription_entitlements for select
  using (
    exists (select 1 from subscriptions s where s.id = subscription_id and s.user_id = auth.uid())
    or is_admin()
  );

-- Atomic rollover + decrement so two concurrent bookings can't both read
-- "1 credit left" and both spend it (plan rule 1: the client is never the
-- source of truth for money — this function is the actual authority the
-- Supabase-backed repository's RPC call defers to).
create or replace function consume_subscription_credit(p_subscription_id uuid) returns subscription_entitlements as $$
declare
  v_plan_type text;
  v_seat_count integer;
  v_granted integer;
  v_row subscription_entitlements;
begin
  select plan_type, seat_count into v_plan_type, v_seat_count from subscriptions where id = p_subscription_id;
  if v_plan_type is null then
    raise exception 'SUBSCRIPTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_granted := case when v_plan_type = 'corporate' then greatest(v_seat_count, 1) else 1 end;

  insert into subscription_entitlements (subscription_id, credits_remaining, reset_at)
  values (p_subscription_id, v_granted, now() + interval '1 month')
  on conflict (subscription_id) do nothing;

  select * into v_row from subscription_entitlements where subscription_id = p_subscription_id for update;

  if now() >= v_row.reset_at then
    v_row.credits_remaining := v_granted;
    v_row.reset_at := v_row.reset_at + interval '1 month';
  end if;

  if v_row.credits_remaining <= 0 then
    raise exception 'NO_CREDITS_REMAINING' using errcode = 'P0003';
  end if;

  v_row.credits_remaining := v_row.credits_remaining - 1;
  update subscription_entitlements
    set credits_remaining = v_row.credits_remaining, reset_at = v_row.reset_at
    where subscription_id = p_subscription_id
    returning * into v_row;

  return v_row;
end;
$$ language plpgsql security definer;
