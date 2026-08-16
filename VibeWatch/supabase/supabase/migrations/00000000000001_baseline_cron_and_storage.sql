-- Complemento alla baseline (F0.a).
--
-- `supabase db dump --schema public` non vede due pezzi di stato che sono
-- altrettanto necessari a ricostruire il progetto da zero:
--   * le schedule pg_cron (schema `cron`), che F0.c tocca direttamente;
--   * i bucket storage e le loro policy (schema `storage`).
--
-- Tutto idempotente: la baseline viene marcata come gia' applicata in
-- produzione (`supabase migration repair --status applied`), quindi questo file
-- gira solo su un DB ricostruito da zero.
--
-- NOTA: i comandi cron leggono `edge_service_key` da `vault.decrypted_secrets`.
-- Su un progetto nuovo quel secret va creato PRIMA, altrimenti i job partono ma
-- ricevono un apikey nullo.

-- ---------------------------------------------------------------- storage ---

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('avatars',     'avatars',     true,   5242880,   ARRAY['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('clips',       'clips',       false,  NULL,      NULL),
  ('imports',     'imports',     false,  209715200, NULL),
  ('update.json', 'update.json', true,   NULL,      NULL)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Il bucket `avatars` e' pubblico in lettura: le policy coprono solo la
-- scrittura. Il prefisso `{uid}-` nel nome file e' cio' che lega l'oggetto al
-- suo proprietario gia' al momento della INSERT (owner non e' ancora valorizzato).
DROP POLICY IF EXISTS "Avatar uploads are scoped to the uploader" ON storage.objects;
CREATE POLICY "Avatar uploads are scoped to the uploader"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND (
      lower(name) LIKE lower(((SELECT auth.uid()))::text) || '-%'
      OR lower(name) LIKE 'avatars/' || lower(((SELECT auth.uid()))::text) || '-%'
    )
  );

DROP POLICY IF EXISTS "Users can update their own avatars" ON storage.objects;
CREATE POLICY "Users can update their own avatars"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'avatars' AND auth.uid() = owner);

DROP POLICY IF EXISTS "Users can delete their own avatars" ON storage.objects;
CREATE POLICY "Users can delete their own avatars"
  ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'avatars' AND owner = auth.uid());

-- `imports` e' privato e partizionato per cartella `{uid}/...`.
DROP POLICY IF EXISTS imports_select_own ON storage.objects;
CREATE POLICY imports_select_own
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'imports'
    AND lower((storage.foldername(name))[1]) = lower(((SELECT auth.uid()))::text)
  );

DROP POLICY IF EXISTS imports_insert_own ON storage.objects;
CREATE POLICY imports_insert_own
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'imports'
    AND lower((storage.foldername(name))[1]) = lower(((SELECT auth.uid()))::text)
  );

DROP POLICY IF EXISTS imports_delete_own ON storage.objects;
CREATE POLICY imports_delete_own
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'imports'
    AND lower((storage.foldername(name))[1]) = lower(((SELECT auth.uid()))::text)
  );

-- Il bucket `clips` non ha policy: e' raggiungibile solo con la service key.

-- ------------------------------------------------------------------- cron ---

DO $$
DECLARE
  j record;
  edge_headers constant text :=
    'jsonb_build_object(''apikey'', (select decrypted_secret from vault.decrypted_secrets where name=''edge_service_key''), ''Content-Type'',''application/json'')';
  edge_headers_auth constant text :=
    'jsonb_build_object(''apikey'', (select decrypted_secret from vault.decrypted_secrets where name=''edge_service_key''), ''Authorization'', ''Bearer '' || (select decrypted_secret from vault.decrypted_secrets where name=''edge_service_key''), ''Content-Type'',''application/json'')';
  base constant text := 'https://rqhxhkijzhqivljivirq.supabase.co/functions/v1/';
BEGIN
  -- pg_cron non esiste sullo shadow database usato da `supabase db diff` ne'
  -- su uno stack locale senza shared_preload_libraries: li' le schedule non
  -- sono ricostruibili e non e' un errore.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron assente: schedule saltate';
    RETURN;
  END IF;

  -- Riscrivere una schedule esistente e' un unschedule + schedule: cron.schedule
  -- con lo stesso jobname aggiorna, ma solo dalla 1.4 in poi. Qui si va sul
  -- sicuro rimuovendo prima cio' che esiste gia'.
  FOR j IN
    SELECT unnest(ARRAY[
      'weekly-content-curator','refresh-backlog','catalog-prewarm','import-driver',
      'imports-cleanup','catalog-refresh','process-notifications','episode-radar',
      'check-all-availability','release-radar','continue-watching-reminder',
      'streak-reminder','prune-user-devices','email-digest','weekly-recap'
    ]) AS name
  LOOP
    PERFORM cron.unschedule(j.name) WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = j.name);
  END LOOP;

  -- Job SQL puri.
  PERFORM cron.schedule('refresh-backlog',     '0 5 * * *',   'select public.refresh_backlog_since()');
  PERFORM cron.schedule('prune-user-devices',  '15 3 * * 0',  'select public.prune_user_devices(5);');

  -- Job che invocano una edge function. Alcuni passano solo apikey, altri anche
  -- Authorization: la differenza e' storica e va preservata cosi' com'e' —
  -- cambiarla qui significherebbe cambiare il comportamento in produzione.
  PERFORM cron.schedule('catalog-prewarm',   '30 3 * * *', format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'catalog-prewarm', edge_headers_auth));
  PERFORM cron.schedule('imports-cleanup',   '40 4 * * *', format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'imports-cleanup', edge_headers_auth));
  PERFORM cron.schedule('catalog-refresh',   '0 4 * * *',  format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'catalog-refresh', edge_headers_auth));
  PERFORM cron.schedule('episode-radar',     '30 5 * * *', format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'episode-radar', edge_headers_auth));

  PERFORM cron.schedule('process-notifications',      '*/5 * * * *', format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'process-notifications', edge_headers));
  PERFORM cron.schedule('check-all-availability',     '0 6 * * *',   format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'check-all-availability', edge_headers));
  PERFORM cron.schedule('release-radar',              '0 7 * * *',   format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'release-radar', edge_headers));
  PERFORM cron.schedule('continue-watching-reminder', '0 18 * * *',  format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'continue-watching-reminder', edge_headers));
  PERFORM cron.schedule('streak-reminder',            '0 20 * * *',  format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'streak-reminder', edge_headers));
  PERFORM cron.schedule('email-digest',               '0 17 * * *',  format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'email-digest', edge_headers));
  PERFORM cron.schedule('weekly-recap',               '0 18 * * 0',  format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'weekly-recap', edge_headers));

  -- import-driver gira ogni minuto ma sveglia la funzione solo se c'e'
  -- davvero un job in corso.
  PERFORM cron.schedule('import-driver', '* * * * *', format(
    'select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb) where exists (select 1 from public.import_jobs where status = ''running'');',
    base||'import-driver', edge_headers_auth));

  -- weekly-content-curator scrive su `discovery_content`, che non esiste:
  -- fallisce ogni domenica da quando e' stato creato. Resta qui per fedelta'
  -- alla baseline; viene rimosso da F0.c.1.
  PERFORM cron.schedule('weekly-content-curator', '0 0 * * 0', format('select net.http_post(url := %L, headers := %s, body := ''{}''::jsonb);', base||'weekly-content-curator', edge_headers));
END $$;
