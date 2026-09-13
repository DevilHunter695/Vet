-- K6: lab test ordering + report delivery.
--
-- Ordering a lab test is not a new booking system: it is just a `Service`
-- of category 'lab_test' booked through the existing cart/checkout/visit
-- flow (see VetCircuit's ServiceCategory.labTest). This table only tracks
-- the report that later attaches to the resulting visit.
--
-- Reports are uploaded ops-side once results are back from the partner lab
-- — that upload tooling is out of this app's scope, so there is
-- deliberately no client insert/update policy at all; the client only ever
-- reads. Access mirrors `pet_documents` (0035_pet_documents.sql): the pet's
-- owner and any household member sharing that owner's household may read.

create table lab_test_reports (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id) on delete cascade,
  pet_id uuid not null references pets(id) on delete cascade,
  test_name text not null,
  status text not null default 'pending' check (status in ('pending', 'ready')),
  -- Storage object path within a private `lab-reports` bucket, e.g.
  -- "lab_test_reports/<visit_id>/<uuid>.pdf" — never a public URL. Null
  -- until the report is ready.
  report_file_path text,
  result_summary text,
  available_at timestamptz,
  created_at timestamptz not null default now()
);

alter table lab_test_reports enable row level security;

-- A household member (owner included) may see every report on a pet they
-- share, matching pet_documents' "pets household select" reach exactly.
create policy "lab_test_reports select household" on lab_test_reports for select
  using (
    exists (
      select 1 from pets p
      where p.id = lab_test_reports.pet_id
        and (
          p.owner_id = auth.uid()
          or exists (
            select 1 from household_members mine
            join household_members theirs on theirs.household_id = mine.household_id
            where mine.user_id = auth.uid() and theirs.user_id = p.owner_id
          )
        )
    )
  );

-- No insert/update/delete policy for any client role on purpose: reports
-- are written ops-side only (service-role), never by the app.

create index lab_test_reports_visit_id_idx on lab_test_reports (visit_id);
create index lab_test_reports_pet_id_idx on lab_test_reports (pet_id);
