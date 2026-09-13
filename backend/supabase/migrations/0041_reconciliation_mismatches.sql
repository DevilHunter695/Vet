-- G8: daily reconciliation — the `daily-reconciliation` Edge Function (run by
-- a cron trigger, or fed a manual ops upload) compares our own `payments`
-- ledger against a gateway settlement report and writes one row here per
-- mismatch it finds. This is inherently an ops/back-office concern: there is
-- no customer-facing read of this table, and none is added (plan §6.2's
-- trusted-boundary table lists reconciliation as an internal job, not an
-- API surface).
--
-- RLS: admin-only read, no insert/update/delete policy for any client role
-- at all — only the Edge Function, using the service-role key (which
-- bypasses RLS), ever writes here. Mirrors reconciliation_mismatches'
-- append-only cousins (wallet_ledger 0026, support_refund_audit 0038): no
-- update/delete grant even for service_role, since a mismatch record should
-- never be silently edited away, only superseded by a fresh run.

create table reconciliation_mismatches (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null,
  -- Present when we have a local payment but the gateway record is missing,
  -- amount-mismatched, or not settled; null when the mismatch is the other
  -- direction (a gateway record with no matching local payment at all).
  payment_id uuid references payments(id) on delete set null,
  gateway_transaction_id text,
  kind text not null check (kind in (
    'missing_in_gateway',   -- we have a payment; no matching settled gateway record
    'missing_in_ledger',    -- gateway settled a transaction we have no payment for
    'amount_mismatch',      -- both exist but amounts differ
    'status_mismatch'       -- gateway record exists but isn't settled/succeeded
  )),
  ledger_amount_minor_units integer,
  gateway_amount_minor_units integer,
  gateway_status text,
  gateway_settled_at timestamptz,
  details text,
  created_at timestamptz not null default now()
);

create index reconciliation_mismatches_run_id_idx on reconciliation_mismatches(run_id);
create index reconciliation_mismatches_payment_id_idx on reconciliation_mismatches(payment_id);

alter table reconciliation_mismatches enable row level security;

revoke delete on reconciliation_mismatches from authenticated, anon, service_role;
revoke update on reconciliation_mismatches from authenticated, anon, service_role;

-- Admin-only read (ops dashboard concern, out of this app's scope) — no
-- insert policy for authenticated/anon at all, so only the service role
-- (used exclusively inside the daily-reconciliation Edge Function) can
-- write a row here.
create policy "reconciliation_mismatches admin read" on reconciliation_mismatches for select
  using (is_admin());
