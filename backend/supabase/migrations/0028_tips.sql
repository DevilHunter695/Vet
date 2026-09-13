-- E11: tip the vet after a completed visit. A tip is a payment row tagged
-- `kind = 'tip'` rather than a new table — it rides the existing
-- payments/RLS machinery, and the credit trigger below is what makes it
-- 100% the vet's, unlike credit_vet_on_visit_completed()'s ~70% split
-- (0014_payouts.sql).

alter table payments add column kind text not null default 'charge' check (kind in ('charge', 'tip'));

-- A tip must reference the visit it's for so the credit trigger knows which
-- vet to pay; subscription payments are never tips.
alter table payments add constraint payments_tip_needs_visit
  check (kind = 'charge' or visit_id is not null);

create or replace function credit_vet_on_tip_succeeded() returns trigger as $$
declare
  v_vet_id uuid;
begin
  if new.kind = 'tip' and new.status = 'succeeded' and old.status is distinct from 'succeeded' then
    select vet_id into v_vet_id from visits where id = new.visit_id;
    if v_vet_id is not null then
      -- 100%, not the 70% visit split — the whole point of a tip.
      insert into vet_ledger (vet_id, visit_id, amount_minor_units, description)
        values (v_vet_id, new.visit_id, new.amount_minor_units, 'Tip');
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger payments_credit_vet_on_tip
  after update of status on payments
  for each row execute function credit_vet_on_tip_succeeded();
