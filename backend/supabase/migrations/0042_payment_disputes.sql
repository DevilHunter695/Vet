-- G9: chargeback/dispute handling from the payment gateway. A dispute is
-- money already on hold with the gateway pending a decision — the customer
-- needs to know one exists on their visit ("why is there a hold?"), but only
-- the gateway's webhook (relayed through the `dispute-webhook` Edge
-- Function) or an admin may ever write one.
--
-- RLS mirrors refunds/wallet_ledger's admin-write/customer-read-own split:
-- a customer can SELECT a dispute tied to one of their own visits (read-only
-- visibility into the hold), but has no insert/update/delete policy at all.

create table payment_disputes (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references payments(id) on delete cascade,
  visit_id uuid not null references visits(id) on delete cascade,
  gateway_dispute_id text not null unique,
  reason text not null,
  amount_minor_units integer not null check (amount_minor_units > 0),
  status text not null default 'open'
    check (status in ('open', 'needs_response', 'won', 'lost')),
  opened_at timestamptz not null default now(),
  resolved_at timestamptz,
  evidence_submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index payment_disputes_visit_id_idx on payment_disputes(visit_id);
create index payment_disputes_payment_id_idx on payment_disputes(payment_id);

alter table payment_disputes enable row level security;

-- Not append-only like wallet_ledger/refunds: a dispute's status legitimately
-- changes over its lifecycle (open -> needs_response -> won/lost) as the
-- gateway relays updates, so update is allowed for service_role (via the
-- dispute-webhook function) but delete never is — a dispute record is never
-- erased, only resolved.
revoke delete on payment_disputes from authenticated, anon, service_role;
revoke update on payment_disputes from authenticated, anon;

-- Customers can see disputes on their own visits ("a payment dispute is
-- under review for this visit") — this is the one part of G9 that is
-- genuinely this app's job. Admins see everything.
create policy "payment_disputes select own visit" on payment_disputes for select
  using (
    is_admin()
    or exists (
      select 1 from visits v where v.id = payment_disputes.visit_id and v.user_id = auth.uid()
    )
  );

-- No insert/update policy for authenticated/anon at all: only the service
-- role (used exclusively inside the dispute-webhook Edge Function, or by an
-- admin tool) can write here.
