-- C7: map view of cluster coverage. Reuses 0004's circuit_cluster_centers
-- (already the source of truth match_cluster() geofences against) rather than
-- a second table that could drift from it; adds the 3km radius match_cluster()
-- hardcodes so the client doesn't need to know that constant.
create or replace view served_clusters as
  select cluster_area as area, lat as latitude, lng as longitude, 3.0 as radius_km
  from circuit_cluster_centers;

grant select on served_clusters to authenticated, anon;
