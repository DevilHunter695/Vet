-- L6: review moderation (profanity, PII, defamation-risk) support columns.
-- `ReviewModerationPolicy` (client-side, pure domain logic) runs BEFORE a
-- review is submitted: profanity rejects the submission outright (never
-- reaches this table), PII is redacted in the text the client sends, and
-- defamation-risk language sets `needs_moderation` so ops can review it —
-- the review itself is still stored and publicly visible, this is a signal
-- for human review, not a block. Additive-only: reviews itself is defined in
-- 0001_init.sql and is never edited here.

alter table reviews
  add column needs_moderation boolean not null default false,
  add column moderation_flags text[] not null default '{}';

create index reviews_needs_moderation_idx on reviews(needs_moderation) where needs_moderation;

comment on column reviews.needs_moderation is
  'Set by the client-side ReviewModerationPolicy when submitted text tripped a PII/defamation-risk check. Flag for human review, not a legal determination.';
comment on column reviews.moderation_flags is
  'Which policy checks tripped, e.g. pii_email, pii_phone, pii_address, defamation_risk.';
