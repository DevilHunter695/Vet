-- C8: search by vet name, service, or symptom. Plan §3 C8 is explicit that
-- "Postgres FTS is enough; do not add a search cluster" — this adds a
-- generated tsvector + GIN index per plan, no external search service.

alter table services add column search_vector tsvector
  generated always as (
    setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(summary, '')), 'B')
  ) stored;

create index services_search_vector_idx on services using gin (search_vector);

alter table vets add column search_vector tsvector
  generated always as (to_tsvector('english', coalesce(name, ''))) stored;

create index vets_search_vector_idx on vets using gin (search_vector);
