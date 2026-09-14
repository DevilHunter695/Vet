-- B2: pet photo — additive column only, mirrors the reference-row-not-bytes
-- discipline already used for pet_documents.file_path.
alter table pets add column if not exists photo_url text;
