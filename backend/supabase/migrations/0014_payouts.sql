-- G7: vet payouts — the plan calls this out explicitly: "Vets quit over
-- late/unclear pay faster than over anything else." An earnings view plus
-- a weekly payout run, backed by an append-only ledger.

create table payouts (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references vets(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  amount_minor_units integer not null check (amount_minor_units >= 0),
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed')),
  gateway_reference text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create index payouts_vet_id_idx on payouts(vet_id);

alter table payouts enable row level security;
create policy "payouts select own" on payouts for select
  using (is_vet(vet_id) or is_admin());

create table vet_ledger (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references vets(id) on delete cascade,
  visit_id uuid references visits(id) on delete set null,
  amount_minor_units integer not null, -- positive = earning, negative = adjustment/clawback
  description text not null,
  -- Set once this entry is swept into a payout run; null = still owed.
  -- The only mutation ever made to a ledger row, and only by the payout
  -- run itself (plan §5.1 "History is never rewritten" otherwise).
  payout_id uuid references payouts(id),
  created_at timestamptz not null default now()
);

create index vet_ledger_vet_id_idx on vet_ledger(vet_id);
create index vet_ledger_unpaid_idx on vet_ledger(vet_id) where payout_id is null;

alter table vet_ledger enable row level security;
revoke delete on vet_ledger from authenticated, anon, service_role;

create policy "vet_ledger select own" on vet_ledger for select
  using (is_vet(vet_id) or is_admin());

-- A visit earns the vet money the moment it completes — the ledger entry
-- is the source of truth for "what you're owed"; a payout row just batches
-- unpaid ledger entries into one payment run (plan §6.5 "weekly").
create or replace function credit_vet_on_visit_completed() returns trigger as $$
declare
  v_payout_minor_units integer;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    -- Flat 70% vet share of a representative visit price stands in for a
    -- real per-service rate lookup, which depends on the pricing/quote
    -- work (§E) knowing what this specific visit was actually charged.
    select coalesce(p.amount_minor_units, 59900) * 7 / 10 into v_payout_minor_units
      from payments p where p.visit_id = new.id;

    insert into vet_ledger (vet_id, visit_id, amount_minor_units, description)
      values (new.vet_id, new.id, v_payout_minor_units, 'Visit completed');
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger visits_credit_vet_on_complete
  after update of status on visits
  for each row execute function credit_vet_on_visit_completed();

-- Weekly payout run (plan §6.5): batches every vet's unswept ledger balance
-- into one payout row per vet, then marks those entries swept so the next
-- run never double-pays them.
create or replace function run_weekly_payouts(p_period_start date, p_period_end date) returns void as $$
declare
  r record;
  v_payout_id uuid;
begin
  for r in
    select vet_id, sum(amount_minor_units) as total
    from vet_ledger
    where payout_id is null
    group by vet_id
    having sum(amount_minor_units) > 0
  loop
    insert into payouts (vet_id, period_start, period_end, amount_minor_units)
      values (r.vet_id, p_period_start, p_period_end, r.total)
      returning id into v_payout_id;

    update vet_ledger set payout_id = v_payout_id where vet_id = r.vet_id and payout_id is null;
  end loop;
end;
$$ language plpgsql security definer;
