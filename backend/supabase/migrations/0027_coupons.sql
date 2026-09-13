-- E4/N2: coupon codes + campaigns. Lookup goes through validate_coupon()
-- only — there is no client select policy on `coupons`, so a code can't be
-- enumerated by scanning the table; the RPC is the only door in.

create table coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  discount_type text not null check (discount_type in ('percentage_off', 'fixed_amount_off')),
  discount_value integer not null check (discount_value > 0),
  max_discount_minor_units integer,
  valid_from timestamptz not null default now(),
  valid_until timestamptz not null,
  usage_limit integer,        -- total redemptions across all users; null = unlimited
  per_user_limit integer,     -- redemptions per user; null = unlimited
  min_spend_minor_units integer,
  campaign_name text,
  created_at timestamptz not null default now()
);

-- Every successful application is recorded here so usage_limit/per_user_limit
-- can be enforced without trusting the client's word that it hasn't used a
-- code before.
create table coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references coupons(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  cart_id uuid references carts(id) on delete set null,
  discount_applied_minor_units integer not null,
  redeemed_at timestamptz not null default now()
);

create index coupon_redemptions_coupon_id_idx on coupon_redemptions(coupon_id);
create index coupon_redemptions_user_id_idx on coupon_redemptions(user_id);

alter table coupons enable row level security;
alter table coupon_redemptions enable row level security;

-- No select policy on `coupons` for authenticated/anon — every read goes
-- through validate_coupon() (security definer), never a direct table query.
create policy "coupons admin manage" on coupons for all
  using (is_admin()) with check (is_admin());

create policy "coupon_redemptions select own" on coupon_redemptions for select
  using (user_id = auth.uid() or is_admin());

-- Validates a code against a specific user/cart total and returns the
-- coupon row only if every rule (window, usage limits, min spend) passes —
-- this is the sole way the app ever learns whether a code exists, so a
-- wrong guess and an out-of-window real code look identical (empty result).
create or replace function validate_coupon(p_code text, p_user_id uuid, p_cart_total integer)
returns setof coupons as $$
declare
  v_coupon coupons;
  v_total_redemptions integer;
  v_user_redemptions integer;
begin
  select * into v_coupon from coupons where lower(code) = lower(p_code);
  if not found then return; end if;

  if now() < v_coupon.valid_from or now() > v_coupon.valid_until then return; end if;
  if v_coupon.min_spend_minor_units is not null and p_cart_total < v_coupon.min_spend_minor_units then return; end if;

  if v_coupon.usage_limit is not null then
    select count(*) into v_total_redemptions from coupon_redemptions where coupon_id = v_coupon.id;
    if v_total_redemptions >= v_coupon.usage_limit then return; end if;
  end if;

  if v_coupon.per_user_limit is not null then
    select count(*) into v_user_redemptions from coupon_redemptions
      where coupon_id = v_coupon.id and user_id = p_user_id;
    if v_user_redemptions >= v_coupon.per_user_limit then return; end if;
  end if;

  return next v_coupon;
end;
$$ language plpgsql security definer;

-- A couple of seed campaigns (plan §N2) so the flow is exercisable without
-- an admin console — mirrors the mock repository's example coupons.
insert into coupons (code, discount_type, discount_value, max_discount_minor_units, valid_until, per_user_limit, min_spend_minor_units, campaign_name) values
  ('FIRSTVISIT', 'percentage_off', 20, 30000, now() + interval '5 years', 1, null, 'First-visit welcome'),
  ('WINBACK100', 'fixed_amount_off', 10000, null, now() + interval '5 years', 1, 20000, 'Win-back');
