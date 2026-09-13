-- F6: vet-initiated reschedule proposals, with customer accept/decline.
-- F7: adds the missing legal transition into no_show_vet (Appendix B) —
-- 0010_visit_otp_and_consent.sql's legal_visit_transitions table already
-- exists, so this is an insert into it, not an edit of that migration.

create table reschedule_proposals (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  proposed_by_role text not null check (proposed_by_role in ('vet', 'customer')),
  proposed_slot_id uuid not null references schedule_slots(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now()
);

create index reschedule_proposals_visit_id_idx on reschedule_proposals(visit_id);

alter table reschedule_proposals enable row level security;

-- Both sides of the visit can see a proposal; only the vet can create one,
-- and only the customer can respond (accept/decline) to a vet-initiated one
-- — mirrors visits' split "customer cancels / vet updates" policies (0001_init.sql).
create policy "reschedule_proposals select participants" on reschedule_proposals for select
  using (exists (select 1 from visits v where v.id = visit_id and (v.user_id = auth.uid() or is_vet(v.vet_id) or is_admin())));

create policy "reschedule_proposals vet insert" on reschedule_proposals for insert
  with check (
    proposed_by_role = 'vet'
    and exists (select 1 from visits v where v.id = visit_id and is_vet(v.vet_id))
  );

create policy "reschedule_proposals customer respond" on reschedule_proposals for update
  using (exists (select 1 from visits v where v.id = visit_id and v.user_id = auth.uid()))
  with check (exists (select 1 from visits v where v.id = visit_id and v.user_id = auth.uid()));

-- F7: a vet no-show is legal from either state a vet is expected but hasn't
-- shown up in yet, mirroring the existing arrived -> no_show_user entry.
insert into legal_visit_transitions (from_status, to_status) values
  ('assigned', 'no_show_vet'),
  ('en_route', 'no_show_vet');
