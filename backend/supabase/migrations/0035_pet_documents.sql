-- B6: document vault — prior vet reports / insurance documents uploaded
-- against a pet. Files themselves live in the `documents` Storage bucket
-- (private, no public access — Storage SDK wiring is a client-side TODO, see
-- `SupabasePetDocumentRepository`); this table only tracks the row/reference.
--
-- Access mirrors `pets household select` (0020_households.sql): the owner
-- and any household member sharing the pet owner's household may select or
-- insert/delete their own uploads. No public/anon access at all.

create table pet_documents (
  id uuid primary key default gen_random_uuid(),
  pet_id uuid not null references pets(id) on delete cascade,
  uploader_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  -- Storage object path within the `documents` bucket, e.g.
  -- "documents/<pet_id>/<uuid>.pdf" — never a public URL.
  file_path text not null,
  uploaded_at timestamptz not null default now()
);

alter table pet_documents enable row level security;

-- A household member (owner included — an owner is a member of their own
-- household per 0020_households.sql's createHousehold flow) may see every
-- document on a pet they share, matching "pets household select"'s reach.
-- A pet with no household at all still works: the pet's own owner is always
-- allowed via the direct ownership check below.
create policy "pet_documents select household" on pet_documents for select
  using (
    exists (
      select 1 from pets p
      where p.id = pet_documents.pet_id
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

-- Only a household member (or the owner) may upload against the pet, and
-- only as themselves (uploader_id = auth.uid()) — no uploading on someone
-- else's behalf.
create policy "pet_documents insert household" on pet_documents for insert
  with check (
    uploader_id = auth.uid()
    and exists (
      select 1 from pets p
      where p.id = pet_documents.pet_id
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

-- A user may delete only their own uploads — someone else's household
-- membership grants visibility (select), never the right to remove another
-- member's upload.
create policy "pet_documents delete own" on pet_documents for delete
  using (uploader_id = auth.uid());

create index pet_documents_pet_id_idx on pet_documents (pet_id);
create index pet_documents_uploader_id_idx on pet_documents (uploader_id);
