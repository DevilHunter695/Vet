-- J4: masked voice calling — real phone numbers never exposed in an API
-- response. This table stores only the proxy number and expiry, never the
-- customer's or vet's actual number (those live in auth/profile tables
-- that this row never joins against in a client-readable policy).

create table call_sessions (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  proxy_number text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index call_sessions_visit_id_idx on call_sessions(visit_id);

alter table call_sessions enable row level security;
create policy "call_sessions select participants" on call_sessions for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_vet(v.vet_id) or is_admin())));

-- Only the trusted start-call function may create one (it's the piece that
-- actually calls Exotel/Twilio to provision the proxy leg).
