-- Ops console additions (plan §Q, §R, Appendix F gap #8): feature flags /
-- kill switches, and an audited manual visit status override.

create table feature_flags (
  name text primary key,
  enabled boolean not null default true,
  description text
);

alter table feature_flags enable row level security;

-- Every client (iOS app, partner-web, admin-web) needs to read flags to
-- decide whether a feature is live — plan §7.1's kill switches only work if
-- the check is unauthenticated-readable.
create policy "feature_flags select all" on feature_flags for select
  using (true);

create policy "feature_flags admin write" on feature_flags for all
  using (is_admin())
  with check (is_admin());

insert into feature_flags (name, enabled, description) values
  ('booking_enabled', true, 'Master switch for creating new visit bookings.'),
  ('chat_enabled', true, 'In-app chat between customer and vet.'),
  ('masked_calling_enabled', true, 'Masked/relay calling between customer and vet (plan §R).');

-- Manual status override (plan §Q: "manual status override (audited)").
-- The normal path is enforce_visit_transition() (migration 0010), which
-- only allows the legal_visit_transitions table's edges. Ops sometimes
-- needs to unstick a visit outside that graph (e.g. a vet's app crashed
-- mid-visit and left it stranded in 'en_route' forever) — this function is
-- the one sanctioned bypass, gated on is_admin() and still logged to
-- visit_events so the override is never silent.
-- Fold the reason into a dedicated column rather than overloading
-- visit_events' to_status — cheaper than a schema change to that table and
-- keeps the override reason queryable alongside the transition it explains.
alter table visit_events add column if not exists override_reason text;

create or replace function admin_override_visit_status(p_visit_id uuid, p_new_status text, p_reason text) returns void as $$
declare
  v_old_status text;
begin
  if not is_admin() then
    raise exception 'FORBIDDEN: admin_override_visit_status requires an admin' using errcode = '42501';
  end if;

  select status into v_old_status from visits where id = p_visit_id for update;
  if v_old_status is null then
    raise exception 'NOT_FOUND: visit % does not exist', p_visit_id using errcode = 'P0002';
  end if;

  alter table visits disable trigger visits_enforce_transition;
  update visits set status = p_new_status where id = p_visit_id;
  alter table visits enable trigger visits_enforce_transition;

  insert into visit_events (visit_id, from_status, to_status, actor_id, override_reason)
  values (p_visit_id, v_old_status, p_new_status, auth.uid(), 'OVERRIDE: ' || p_reason);
exception when others then
  alter table visits enable trigger visits_enforce_transition;
  raise;
end;
$$ language plpgsql security definer;

revoke all on function admin_override_visit_status(uuid, text, text) from public;
grant execute on function admin_override_visit_status(uuid, text, text) to authenticated;
