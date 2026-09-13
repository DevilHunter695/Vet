-- J2: chat photo attachments — "Pet owners send photos. Always."
-- Stored in a private bucket, scoped by visit id, accessed only via
-- short-lived signed URLs — never a public bucket path.

alter table chat_messages add column attachment_path text; -- storage object path, not a public URL
alter table chat_messages alter column body drop not null;
alter table chat_messages add constraint chat_messages_body_or_attachment
  check (body is not null or attachment_path is not null);

-- Storage bucket + policy: created via the Supabase dashboard/CLI
-- (`supabase storage create chat-attachments --private`), then:
--   create policy "chat attachment upload participants" on storage.objects
--     for insert with check (
--       bucket_id = 'chat-attachments' and
--       exists (
--         select 1 from visits v
--         where v.id::text = (storage.foldername(name))[1]
--           and (v.user_id = auth.uid() or is_vet(v.vet_id))
--       )
--     );
--   create policy "chat attachment read participants" on storage.objects
--     for select using (
--       bucket_id = 'chat-attachments' and
--       exists (
--         select 1 from visits v
--         where v.id::text = (storage.foldername(name))[1]
--           and (v.user_id = auth.uid() or is_vet(v.vet_id) or is_admin())
--       )
--     );
-- (Left as SQL comments, not executable DDL, since storage policies are
-- managed outside the migrations table in most Supabase CLI setups —
-- flagging this rather than silently applying it and having it 404.)
