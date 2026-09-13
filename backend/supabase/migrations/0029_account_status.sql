-- A11: blocked/deactivated account handling. `account_status` needs the same
-- "owner reads, only an admin writes" split as `vets.verification_status`,
-- but unlike that column, "users update own" (0001_init.sql) has no
-- column-level restriction — RLS is row-level, so a client updating their own
-- profile row could otherwise slip a status change through the general
-- update policy. A trigger (same shape as `enforce_visit_transition` in
-- 0010_visit_otp_and_consent.sql) closes that gap without touching the
-- existing policy.

alter table users add column account_status text not null default 'active'
  check (account_status in ('active', 'blocked', 'deactivated'));

create or replace function enforce_account_status_admin_only() returns trigger as $$
begin
  if old.account_status is distinct from new.account_status and not is_admin() then
    raise exception 'ACCOUNT_STATUS_ADMIN_ONLY' using errcode = 'P0001';
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger users_account_status_admin_only
  before update of account_status on users
  for each row execute function enforce_account_status_admin_only();
