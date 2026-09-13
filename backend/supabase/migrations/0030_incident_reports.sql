-- L4/L5: incident reporting (SOS + safety concerns), filed by either party.
-- Deliberately separate from `support_tickets` (0001_init.sql) — see the
-- doc comment on `IncidentReport` in Domain/Models/Models.swift for why a
-- safety report isn't modeled as "a ticket with a different subject".
-- Ops-side listing/vet-suspension is out of scope here — only the
-- reporter's own read/write path is built.

create table incident_reports (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reporter_role text not null check (reporter_role in ('customer', 'vet')),
  type text not null check (type in ('sos', 'safety_concern', 'unprofessional_conduct', 'other')),
  description text not null default '',
  created_at timestamptz not null default now()
);

alter table incident_reports enable row level security;

-- A reporter can file and read only their own reports. Ops-console-wide
-- visibility (is_admin()) is intentionally included here since the helper
-- already exists and costs nothing extra to grant — the ops UI itself is
-- out of scope, not the read access it would need.
create policy "incident_reports insert own" on incident_reports for insert
  with check (reporter_id = auth.uid());
create policy "incident_reports select own" on incident_reports for select
  using (reporter_id = auth.uid() or is_admin());

create index incident_reports_visit_id_idx on incident_reports (visit_id);
create index incident_reports_reporter_id_idx on incident_reports (reporter_id);
