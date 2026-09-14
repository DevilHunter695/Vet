-- A5: edit profile needs a photo and a language preference on `users`
-- itself — additive columns only, same discipline as 0050_pet_photo_url.sql.
-- `photo_url` is a reference into the existing private `documents` bucket
-- (path `profile-photos/<userId>/<uuid>.jpg`), never raw bytes in the row.
alter table users add column if not exists photo_url text;
alter table users add column if not exists preferred_language text;
