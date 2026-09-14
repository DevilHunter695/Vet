-- I2: a timestamped status timeline (requested -> confirmed -> assigned ->
-- en route -> arrived -> in progress -> completed), not just the current
-- badge `visits.status` already gives you. This table is the append-only
-- log of every transition Visit.legalTransitions allows, each with the
-- moment it actually happened — the client can't reconstruct history it was
-- never told, so past timestamps have to live server-side.
--
-- Written only by the trigger below (mirrors `wallet_ledger`/`refunds`'
-- append-only discipline): a client cannot insert/update/delete rows here
-- directly, only ever cause them indirectly by changing `visits.status`
-- through the existing, already-guarded visit-update path.

create table visit_status_events (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  status text not null,
  occurred_at timestamptz not null default now()
);

alter table visit_status_events enable row level security;

create policy "visit_status_events select own" on visit_status_events for select
  using (
    exists (select 1 from visits v where v.id = visit_status_events.visit_id and v.user_id = auth.uid())
  );

-- No insert/update/delete policy for any client role: rows are only ever
-- created by the trigger below, running as the table owner.

create index visit_status_events_visit_id_idx on visit_status_events (visit_id, occurred_at);

-- Logs the visit's initial status once, and every subsequent status change
-- — this is the one place that actually knows "when", so it's also the one
-- place allowed to write it.
create or replace function log_visit_status_event() returns trigger as $$
begin
  if tg_op = 'INSERT' then
    insert into visit_status_events (visit_id, status, occurred_at) values (new.id, new.status, now());
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    insert into visit_status_events (visit_id, status, occurred_at) values (new.id, new.status, now());
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger visits_log_status_event
  after insert or update of status on visits
  for each row execute function log_visit_status_event();
