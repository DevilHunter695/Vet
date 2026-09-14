-- E8: pay-after-visit — a payment can now sit in a distinct
-- 'pay_after_visit' status (booked/confirmed against a real signed quote,
-- but no gateway charge has run yet: gateway_reference stays null) until a
-- future "mark collected" step moves it to 'succeeded' once the vet
-- collects cash/UPI on-site, mirroring how a gateway webhook is the only
-- thing that ever marks a prepaid payment 'succeeded'.
--
-- Additive: widens the existing status CHECK constraint from
-- 0001_init.sql, does not touch any existing row or column.
alter table payments
  drop constraint payments_status_check;

alter table payments
  add constraint payments_status_check
    check (status in ('pending', 'succeeded', 'failed', 'refunded', 'pay_after_visit'));
