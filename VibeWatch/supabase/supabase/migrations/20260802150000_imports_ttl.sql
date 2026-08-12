-- SPEC v3 §7.2 — "ZIP caricato in Storage (bucket privato `imports`, TTL 7 giorni)".
--
-- Il TTL dichiarato dalla spec NON esisteva: gli ZIP — export GDPR di terzi, con dentro lo
-- storico di visione di una persona — restavano in Storage per sempre. Questa migration
-- aggiunge la metà SQL della pulizia: la funzione che elenca i candidati. La cancellazione
-- vera la fa la Edge Function `imports-cleanup` via Storage API (cron giornaliero, migration
-- successiva): cancellare righe da `storage.objects` a mano lascerebbe i byte orfani su S3 —
-- la riga sparirebbe, il file no. Il TTL sarebbe una finzione, che per un dato personale è
-- peggio che mancare.
--
-- Perché una funzione e non una query dentro la Edge Function: lo schema `storage` non è
-- esposto via PostgREST, e la conoscenza "cosa è stale" sta meglio in un punto solo, accanto
-- a `create_import_job` che di `storage.objects` già si fida per l'esistenza del file.

create or replace function public.imports_stale_uploads(
  p_older_than interval default interval '7 days'
)
returns table(name text)
language sql
security definer
set search_path = public
as $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'imports'
     and o.created_at < now() - p_older_than
     -- Un job aperto tiene in vita il proprio file anche oltre il TTL: la fase 2 lo sta
     -- ancora leggendo, e strapparglielo trasformerebbe la pulizia in una causa di failed.
     -- I job `failed` invece NON lo tengono: il TTL è la promessa di §7.2, e un retry oltre
     -- i 7 giorni risponde `upload_not_found` — visibile, e si risolve ricaricando lo ZIP.
     and not exists (
       select 1 from public.import_jobs j
        where j.status in ('running', 'paused')
          and j.storage_path = o.name
     )
   order by o.created_at
   -- Lavoro limitato per giro: il cron è giornaliero, il residuo passa al giro dopo. La Edge
   -- Function dichiara nel proprio esito se il limite è stato toccato — niente tagli muti.
   limit 200;
$$;

comment on function public.imports_stale_uploads(interval) is
  'SPEC v3 §7.2: i file del bucket imports oltre il TTL (default 7 giorni), esclusi quelli '
  'di job ancora aperti. Solo elenco: la cancellazione la fa imports-cleanup via Storage API.';

-- Solo il servizio. La lezione di `import_touched_shows`: i default privileges di Supabase
-- regalano EXECUTE ad anon/authenticated alla creazione — si revoca a tutti e tre, esplicito,
-- e fa fede `proacl`, non il revoke che si è scritto.
revoke all on function public.imports_stale_uploads(interval) from public;
revoke all on function public.imports_stale_uploads(interval) from anon;
revoke all on function public.imports_stale_uploads(interval) from authenticated;
grant execute on function public.imports_stale_uploads(interval) to service_role;
