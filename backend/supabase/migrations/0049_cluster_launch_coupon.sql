-- N2: the third named campaign type from the plan (first-visit, win-back,
-- cluster-launch) — 0027_coupons.sql only seeded the first two. Additive
-- only: no existing row touched, validated through the same validate_coupon()
-- RPC as every other code.
insert into coupons (code, discount_type, discount_value, max_discount_minor_units, valid_until, usage_limit, min_spend_minor_units, campaign_name)
values ('CLUSTERLAUNCH', 'percentage_off', 15, 20000, now() + interval '5 years', 500, null, 'Cluster launch');
