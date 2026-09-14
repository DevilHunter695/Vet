-- K1: structured visit record — diagnosis notes, procedures performed, and
-- medications given as distinct fields rather than one free-text blob.
-- Additive only: the legacy `notes` column is untouched and still populated
-- for older visits; new/updated visits can populate these instead or
-- alongside it. Written by the attending vet / ops tooling (out of this
-- app's scope, same trust boundary as `notes` already was); this app only
-- ever reads them.
ALTER TABLE visits
    ADD COLUMN IF NOT EXISTS diagnosis_notes text,
    ADD COLUMN IF NOT EXISTS procedures_performed text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS medications_given text[] NOT NULL DEFAULT '{}';
