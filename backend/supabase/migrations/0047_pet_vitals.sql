-- B3: vitals beyond weight (temperature, heart rate) on the same pet_weights
-- reading — additive-only columns, both optional.
alter table pet_weights add column if not exists temperature_celsius numeric;
alter table pet_weights add column if not exists heart_rate_bpm integer;
