-- M4: audit trail for refunds/wallet credits issued by a support agent from
-- a ticket. Append-only, admin/support-role read only, no client write
-- policy at all — the only writer is the `issue-support-refund` Edge
-- Function, using the service-role key, exactly like `refunds` and
-- `wallet_ledger` (0026_wallet_ledger.sql) are never written directly by a
-- client role.

create table support_refund_audit (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references support_tickets(id) on delete cascade,
  visit_id uuid not null references visits(id) on delete cascade,
  issued_by_user_id uuid not null references users(id),
  kind text not null check (kind in ('refund', 'wallet_credit')),
  amount_minor_units integer not null check (amount_minor_units > 0),
  reason text not null,
  refund_id uuid references refunds(id) on delete set null,
  wallet_ledger_entry_id uuid references wallet_ledger(id) on delete set null,
  created_at timestamptz not null default now()
);

create index support_refund_audit_ticket_id_idx on support_refund_audit(ticket_id);
create index support_refund_audit_visit_id_idx on support_refund_audit(visit_id);

alter table support_refund_audit enable row level security;

-- Append-only: no update, no delete, from any role including service_role's
-- default grants (mirrors wallet_ledger's discipline exactly).
revoke delete on support_refund_audit from authenticated, anon, service_role;
revoke update on support_refund_audit from authenticated, anon, service_role;

-- Read is admin/support-role only — a customer never sees who issued their
-- refund or why, only that it happened (via the existing `refunds` /
-- `wallet_ledger` select-own policies).
create policy "support_refund_audit admin read" on support_refund_audit for select
  using (is_admin());

-- No insert policy for authenticated/anon at all: only the service role
-- (used exclusively inside the issue-support-refund Edge Function) can
-- write a row here.
