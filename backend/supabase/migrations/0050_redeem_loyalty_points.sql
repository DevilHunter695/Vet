-- E5: loyalty point redemption at checkout. A single security-definer
-- function performs both mutations (deduct points, credit wallet_ledger)
-- atomically, so the client never gets a partial "points gone, wallet not
-- credited" state, and never needs (nor gets) a general-purpose wallet-write
-- policy — this is the one narrow, self-service exception to
-- wallet_ledger's "no client insert policy at all" (0026_wallet_ledger.sql).
--
-- Conversion rate mirrors LoyaltyRedemptionPolicy.swift: 1 point = 50 paise.
create or replace function redeem_loyalty_points(p_user_id uuid, p_points integer)
returns setof loyalty_accounts
language plpgsql
security definer
as $$
declare
  v_available integer;
begin
  if p_user_id <> auth.uid() then
    raise exception 'Can only redeem your own points';
  end if;
  if p_points < 100 then
    raise exception 'Redeem at least 100 points at a time';
  end if;

  select points into v_available from loyalty_accounts where user_id = p_user_id for update;
  if v_available is null or v_available < p_points then
    raise exception 'Not enough points to redeem';
  end if;

  update loyalty_accounts
    set points = points - p_points,
        tier = case
          when points - p_points < 200 then 'bronze'
          when points - p_points < 600 then 'silver'
          else 'gold'
        end
    where user_id = p_user_id;

  insert into wallet_ledger (user_id, amount_minor_units, reason)
    values (p_user_id, p_points * 50, 'Loyalty points redeemed');

  return query select * from loyalty_accounts where user_id = p_user_id;
end;
$$;

grant execute on function redeem_loyalty_points(uuid, integer) to authenticated;
