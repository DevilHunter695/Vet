-- D4 follow-up: real "3 of 4 visits used" redemption tracking for
-- packages/bundles. 0016_packages.sql's own comment names the exact gap this
-- closes — buying a package only ever expanded into plain cart_items, and
-- `visits` carried no reference back to "which package entitlement did this
-- consume". This migration is additive only: it adds a new table plus new,
-- nullable columns on `visits`, and replaces `book_visit()` (defined in
-- 0008_book_visit.sql) with a version that also accepts and redeems against
-- one, rather than editing either of those files in place.

create table package_redemptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  package_id uuid not null references packages(id) on delete restrict,
  package_item_id uuid not null references package_items(id) on delete restrict,
  service_id uuid not null references services(id) on delete restrict,
  total_count integer not null check (total_count > 0),
  used_count integer not null default 0 check (used_count >= 0),
  purchased_at timestamptz not null default now(),
  check (used_count <= total_count)
);

create index package_redemptions_user_id_idx on package_redemptions(user_id);

-- D4: `visits` never carried *what* was booked (service/variant) at all, let
-- alone a package link — this is the structural gap 0016_packages.sql's own
-- comment and Appendix F flagged. All nullable: a visit booked outside the
-- cart/checkout pipeline, or one that predates this migration, simply has
-- none of these set.
alter table visits add column service_id uuid references services(id) on delete set null;
alter table visits add column variant_id uuid references service_variants(id) on delete set null;
alter table visits add column package_redemption_id uuid references package_redemptions(id) on delete set null;

-- ---------------------------------------------------------------------------
-- Row Level Security: mirrors 0007_cart_and_quotes.sql's "carts all own"
-- pattern — a customer can read and create their own redemptions (created at
-- purchase time by BuyPackageUseCase), but `used_count` is only ever
-- advanced by book_visit() below (security definer), never by a direct
-- client update — the same "trusted-path-only write" discipline
-- 0007_cart_and_quotes.sql's "quotes select own" comment documents for quotes.
-- ---------------------------------------------------------------------------
alter table package_redemptions enable row level security;

create policy "package_redemptions select own" on package_redemptions for select
  using (user_id = auth.uid() or is_admin());

create policy "package_redemptions insert own" on package_redemptions for insert
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- book_visit(): same atomic slot-lock + capacity-check + insert transaction
-- as 0008_book_visit.sql, extended to record what was actually booked
-- (service/variant) and, when the booking is redeeming a package
-- entitlement, to lock and bump that redemption's used_count in the same
-- transaction — so a retried call (same idempotency key) can never
-- double-redeem, and a redemption that's already exhausted is rejected
-- before the visit is ever inserted.
-- ---------------------------------------------------------------------------
create or replace function book_visit(
  p_pet_id uuid, p_vet_id uuid, p_circuit_id uuid, p_slot_id uuid,
  p_scheduled_at timestamptz, p_idempotency_key text,
  p_service_id uuid default null, p_variant_id uuid default null,
  p_package_redemption_id uuid default null
) returns visits language plpgsql security definer as $$
declare
  v_visit visits;
  v_existing_visit_id uuid;
  v_capacity integer;
  v_booked_count integer;
  v_redemption_total integer;
  v_redemption_used integer;
begin
  -- Same key already processed: return the original result, don't re-run.
  select visit_id into v_existing_visit_id from idempotency_keys where key = p_idempotency_key;
  if v_existing_visit_id is not null then
    select * into v_visit from visits where id = v_existing_visit_id;
    return v_visit;
  end if;

  -- Lock the slot row so a concurrent call can't read a stale booked_count.
  select capacity, booked_count into v_capacity, v_booked_count
    from schedule_slots where id = p_slot_id for update;

  if v_capacity is null then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_booked_count >= v_capacity then
    raise exception 'SLOT_FULL' using errcode = 'P0001';
  end if;

  -- D4: lock the redemption row too, so two concurrent bookings against the
  -- same "3 of 4 used" entitlement can't both read it as having a slot left.
  if p_package_redemption_id is not null then
    select total_count, used_count into v_redemption_total, v_redemption_used
      from package_redemptions where id = p_package_redemption_id and user_id = auth.uid()
      for update;

    if v_redemption_total is null then
      raise exception 'PACKAGE_REDEMPTION_NOT_FOUND' using errcode = 'P0002';
    end if;

    if v_redemption_used >= v_redemption_total then
      raise exception 'PACKAGE_REDEMPTION_EXHAUSTED' using errcode = 'P0001';
    end if;
  end if;

  insert into visits (user_id, pet_id, vet_id, circuit_id, status, scheduled_at, service_id, variant_id, package_redemption_id)
    values (auth.uid(), p_pet_id, p_vet_id, p_circuit_id, 'requested', p_scheduled_at, p_service_id, p_variant_id, p_package_redemption_id)
    returning * into v_visit;

  update schedule_slots set booked_count = booked_count + 1 where id = p_slot_id;

  if p_package_redemption_id is not null then
    update package_redemptions set used_count = used_count + 1 where id = p_package_redemption_id;
  end if;

  insert into idempotency_keys (key, visit_id) values (p_idempotency_key, v_visit.id);

  return v_visit;
end;
$$;
