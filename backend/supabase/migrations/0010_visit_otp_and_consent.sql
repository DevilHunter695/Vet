-- I5 (start-of-visit OTP), I6 (consent), and the 8-state machine's
-- append-only audit trail (plan §5.1: "History is never rewritten").

alter table visits drop constraint visits_status_check;
alter table visits add constraint visits_status_check check (status in (
  'requested', 'confirmed', 'assigned', 'en_route', 'arrived', 'in_progress',
  'completed', 'cancelled_by_user', 'cancelled_by_vet', 'no_show_user', 'no_show_vet',
  'disputed', 'resolved'
));

create table visit_otps (
  visit_id uuid primary key references visits(id) on delete cascade,
  code text not null,
  expires_at timestamptz not null,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

alter table visit_otps enable row level security;

-- The code itself is never readable by the vet's row — only the customer
-- (who reads it aloud) and ops can see it; the vet side only calls
-- verify_visit_otp() below, which returns a boolean, never the code.
create policy "visit_otps select customer" on visit_otps for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_admin())));

create or replace function verify_visit_otp(p_visit_id uuid, p_code text) returns boolean as $$
declare
  v_match boolean;
begin
  select (code = p_code and expires_at > now() and verified_at is null)
    into v_match from visit_otps where visit_id = p_visit_id;

  if v_match then
    update visit_otps set verified_at = now() where visit_id = p_visit_id;
    update visits set status = 'in_progress' where id = p_visit_id and status = 'arrived';
  end if;

  return coalesce(v_match, false);
end;
$$ language plpgsql security definer;

create table consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  purpose text not null,
  version text not null,
  granted_at timestamptz not null default now(),
  withdrawn_at timestamptz
);

create index consents_user_id_idx on consents(user_id);

alter table consents enable row level security;
create policy "consents all own" on consents for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- Append-only audit of every visit status transition (plan §5.1, Appendix B:
-- "Illegal transitions are rejected by a DB trigger and logged to audit_log").
create table visit_events (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  from_status text,
  to_status text not null,
  actor_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index visit_events_visit_id_idx on visit_events(visit_id);
alter table visit_events enable row level security;
create policy "visit_events select participants" on visit_events for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_vet(v.vet_id) or is_admin())));

-- Revoke UPDATE/DELETE even from service role, per plan §5.1 — this table
-- is a record of what happened, not a place to edit history.
revoke update, delete on visit_events from authenticated, anon, service_role;

create table legal_visit_transitions (
  from_status text not null,
  to_status text not null,
  primary key (from_status, to_status)
);

insert into legal_visit_transitions (from_status, to_status) values
  ('requested', 'confirmed'), ('requested', 'cancelled_by_user'), ('requested', 'cancelled_by_vet'),
  ('confirmed', 'assigned'), ('confirmed', 'cancelled_by_user'), ('confirmed', 'cancelled_by_vet'),
  ('assigned', 'en_route'), ('assigned', 'cancelled_by_user'), ('assigned', 'cancelled_by_vet'),
  ('en_route', 'arrived'), ('en_route', 'cancelled_by_vet'),
  ('arrived', 'in_progress'), ('arrived', 'no_show_user'),
  ('in_progress', 'completed'),
  ('completed', 'disputed'),
  ('disputed', 'resolved');

create or replace function enforce_visit_transition() returns trigger as $$
begin
  if old.status is distinct from new.status then
    if not exists (select 1 from legal_visit_transitions where from_status = old.status and to_status = new.status) then
      raise exception 'ILLEGAL_VISIT_TRANSITION: % -> %', old.status, new.status using errcode = 'P0003';
    end if;
    insert into visit_events (visit_id, from_status, to_status, actor_id) values (new.id, old.status, new.status, auth.uid());
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger visits_enforce_transition
  before update of status on visits
  for each row execute function enforce_visit_transition();
