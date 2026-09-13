-- G4 (refunds) + G5 (GST-compliant invoices) + F3 reschedule support.

create table refunds (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  payment_id uuid not null references payments(id) on delete restrict,
  amount_minor_units integer not null check (amount_minor_units > 0),
  reason text not null,
  status text not null default 'pending' check (status in ('pending', 'processed', 'failed')),
  initiated_by_ops_user_id uuid references auth.users(id), -- null = automatic per-policy refund
  created_at timestamptz not null default now()
);

create index refunds_visit_id_idx on refunds(visit_id);

create table invoices (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null unique references visits(id) on delete cascade,
  invoice_number text not null unique,
  breakdown jsonb not null,
  gst_minor_units integer not null check (gst_minor_units >= 0),
  issued_at timestamptz not null default now()
);

alter table refunds enable row level security;
alter table invoices enable row level security;

-- Refunds are visible to the visit owner, but only a trusted server context
-- (service role, in an Edge Function that actually calls the gateway) may
-- insert one — a customer reads that a refund happened, never writes it.
create policy "refunds select own" on refunds for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_admin())));

create policy "invoices select own" on invoices for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_admin())));

-- Sequential, GST-compliant invoice numbering (plan §G5, §8.7 GST
-- registration requirement) — a Postgres sequence, not a client-guessed counter.
create sequence invoice_number_seq start 1;

create or replace function next_invoice_number() returns text as $$
  select 'VC-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('invoice_number_seq')::text, 6, '0');
$$ language sql;
