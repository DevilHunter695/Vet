-- L2: document-backed vet onboarding — degree, VCI (Veterinary Council of
-- India) certificate, government ID, police verification, and a photo. This
-- is fundamentally a vet-side application reviewed by ops/admin, not a
-- customer-app feature; the table exists so the domain/data layer can be
-- real and correct even though the customer app has no UI surface to
-- submit or review one from (see VetOnboardingRepository doc comment).
--
-- RLS shape mirrors 0021_pet_health_records.sql's "owner reads/writes own
-- row, admin sees/edits all" pattern, with one addition: the applicant's
-- own update is only allowed while the row is still `submitted` — once ops
-- has moved it to `under_review`/`approved`/`rejected`, the applicant can
-- no longer edit it. No delete policy for anyone: an application is a
-- permanent record even if rejected.

create table vet_onboarding_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_user_id uuid not null references users(id) on delete cascade,
  degree_document_url text not null,
  vci_certificate_url text not null,
  id_document_url text not null,
  police_verification_url text not null,
  photo_url text not null,
  status text not null default 'submitted'
    check (status in ('submitted', 'under_review', 'approved', 'rejected')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  review_notes text
);

create index vet_onboarding_applications_applicant_idx on vet_onboarding_applications(applicant_user_id);
create index vet_onboarding_applications_status_idx on vet_onboarding_applications(status);

alter table vet_onboarding_applications enable row level security;

-- Applicant can see their own application(s); admins can see all.
create policy "vet onboarding select own or admin" on vet_onboarding_applications
  for select
  using (applicant_user_id = auth.uid() or is_admin());

-- Applicant can create their own application (must be the applicant on the
-- row they're inserting).
create policy "vet onboarding insert own" on vet_onboarding_applications
  for insert
  with check (applicant_user_id = auth.uid());

-- Applicant can update their own row only while it is still `submitted`;
-- admins can update any row at any status (to move it through review).
create policy "vet onboarding update own while submitted or admin" on vet_onboarding_applications
  for update
  using (
    (applicant_user_id = auth.uid() and status = 'submitted')
    or is_admin()
  )
  with check (
    (applicant_user_id = auth.uid() and status = 'submitted')
    or is_admin()
  );

-- No delete policy for anyone (applicant or admin) — an application is a
-- permanent record.

comment on table vet_onboarding_applications is
  'L2: vet applicant document submissions (degree, VCI certificate, ID, police verification, photo) for admin/ops review. No client UI in this app submits/reviews these; the table and RLS exist as the correct server-side authority for whenever a vet-facing surface is built.';
comment on column vet_onboarding_applications.status is
  'submitted (applicant can still edit) -> under_review -> approved | rejected (admin-only from here).';
