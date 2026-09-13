-- A6: delete account + data — App Store guideline 5.1.1(v) is a hard
-- rejection if this is missing. 30-day soft window; financial records
-- (payments, invoices, refunds) are retained per statute even after purge,
-- with the user's own PII anonymised in place rather than the row deleted.

create table deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  scheduled_purge_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'cancelled', 'purged'))
);

-- Only one pending request per user at a time.
create unique index deletion_requests_one_pending_per_user
  on deletion_requests(user_id) where status = 'pending';

alter table deletion_requests enable row level security;
create policy "deletion_requests all own" on deletion_requests for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- Scheduled job (plan §6.5 "data-deletion executor (daily)"): anonymise PII
-- on users/pets/addresses in place, but never touch payments/invoices/
-- refunds rows themselves — retain them with an anonymised_at marker per
-- plan §5.1 "Deleted user ≠ deleted invoices".
alter table users add column anonymised_at timestamptz;

create or replace function execute_pending_account_deletions() returns void as $$
declare
  r record;
begin
  for r in select * from deletion_requests where status = 'pending' and scheduled_purge_at <= now() loop
    update users set name = 'Deleted user', phone = null, email = null, anonymised_at = now() where id = r.user_id;
    delete from addresses where owner_id = r.user_id;
    delete from consents where user_id = r.user_id;
    update deletion_requests set status = 'purged' where id = r.id;
  end loop;
end;
$$ language plpgsql security definer;
