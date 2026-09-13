-- G6: customer wallet, backed by an append-only ledger — same discipline as
-- vet_ledger (0014_payouts.sql): a balance is a derived sum, never a mutable
-- column, so a credit/refund/compensation can never be silently altered.

create table wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  amount_minor_units integer not null, -- positive = credit, negative = debit
  reason text not null,
  related_visit_id uuid references visits(id) on delete set null,
  related_refund_id uuid references refunds(id) on delete set null,
  created_at timestamptz not null default now()
);

create index wallet_ledger_user_id_idx on wallet_ledger(user_id);

alter table wallet_ledger enable row level security;
-- Append-only, matching vet_ledger exactly (plan §5.1 "History is never
-- rewritten"): no update, no delete, from any role including service_role's
-- default grants — a credit/debit is corrected with an offsetting entry,
-- never edited away.
revoke delete on wallet_ledger from authenticated, anon, service_role;
revoke update on wallet_ledger from authenticated, anon, service_role;

create policy "wallet_ledger select own" on wallet_ledger for select
  using (user_id = auth.uid() or is_admin());

-- No insert policy for authenticated/anon at all — a customer can see their
-- balance but can never credit or debit themselves; only server-side code
-- (service_role, via Edge Functions/triggers) writes entries.
