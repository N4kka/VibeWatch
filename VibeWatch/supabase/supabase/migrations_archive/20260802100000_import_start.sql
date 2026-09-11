-- SPEC v3 §7.2 — l'ingresso dell'import: il client crea il job, il server lo porta a `done`.
--
-- Fin qui la pipeline (fasi 2-6) esisteva ma non aveva una porta: `import_jobs` ha sole policy
-- di lettura — scelta giusta: un client che potesse scrivere `phase` dichiarerebbe finito un
-- import monco — e nei collaudi la riga del job la creava la chiave di servizio. Questa
-- migration aggiunge le tre porte che mancavano, e niente altro:
--
--   * `create_import_job(p_storage_path)` — l'unica scrittura concessa al client, nella forma
--     piu' stretta possibile: un .zip nella PROPRIA cartella del bucket `imports`, gia'
--     caricato. Tutto il resto della riga nasce dai default della tabella.
--   * `retry_import_job(p_job_id)` — riporta un job `failed` a `running`. La ripresa e' sicura
--     per costruzione: i checkpoint (§7.2) dicono da dove, la `dedup_key` (fase 4) impedisce i
--     doppi.
--   * `import_apply_mutations(p_user, batch)` — il pezzo che rende vero "l'utente puo' chiudere
--     l'app" (§7.2). La fase 4 scrive via `apply_mutations`, che si ancora ad `auth.uid()`:
--     con la chiave di servizio solleva `unauthenticated`, e ad app chiusa un JWT utente non
--     esiste. Il wrapper — eseguibile SOLO da `service_role`, fa fede `proacl` — imposta
--     l'identita' del proprietario del job per la durata della transazione e delega: cosi' ogni
--     guardia di `apply_mutations` (cancello d'identita' compreso) resta al suo posto, invece
--     di nascere una versione "fidata" che le duplica.

-- Un solo job aperto per utente. Il controllo sta nell'indice e non in un `if` dentro la
-- funzione: fra il controllo e la scrittura c'e' una finestra, ed e' la stessa ragione per cui
-- `set_username` chiude la corsa sull'indice unico invece che sulla verifica (§3.7).
create unique index if not exists import_jobs_one_open_per_user
  on public.import_jobs (user_id)
  where status in ('running', 'paused');

-- Il lease del driver. Il cron parte ogni minuto ma un giro puo' durare di piu' (una singola
-- invocazione di `import-resolve` su un blocco pieno sfora il minuto): senza un claim atomico
-- due driver farebbero avanzare lo stesso job insieme — la stessa corsa per cui il client NON
-- guida le fasi. Il driver reclama con
--   `update ... set locked_until = now() + lease where id = X and (locked_until is null or
--    locked_until < now()) returning id`
-- rinnova a ogni passo, e se muore il lease scade da solo: nessun job resta orfano.
alter table public.import_jobs
  add column if not exists locked_until timestamptz;

-- L'unica scrittura del client su `import_jobs`. `security definer` perche' la tabella non ha
-- (e non deve avere) policy di INSERT; l'identita' non arriva da un parametro — e' `auth.uid()`,
-- la lezione dell'IDOR di `import-parse`.
create or replace function public.create_import_job(p_storage_path text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
  v_job uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- Un solo segmento dentro la propria cartella, estensione .zip. Non e' una difesa di
  -- cortesia: le policy del bucket confinano gia' l'upload, ma questa funzione e' definer e
  -- DEVE rifiutare da sola un path altrui — non puo' appoggiarsi a una RLS che non la riguarda.
  if p_storage_path is null
     or p_storage_path !~ ('^' || v_uid::text || '/[^/]+\.zip$') then
    return jsonb_build_object('ok', false, 'reason', 'bad_path');
  end if;

  -- Il file deve esserci davvero, e deve averlo caricato il chiamante. Senza questo controllo
  -- un job nascerebbe `uploaded` su un path vuoto e fallirebbe alla fase 2 con un errore che
  -- parla di storage: la stessa notizia, data piu' tardi e peggio.
  if not exists (
    select 1 from storage.objects o
     where o.bucket_id = 'imports'
       and o.name = p_storage_path
       and (o.owner = v_uid or o.owner_id = v_uid::text)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'upload_not_found');
  end if;

  begin
    insert into public.import_jobs (user_id, source, storage_path)
    values (v_uid, 'tvtime', p_storage_path)
    returning id into v_job;
  exception when unique_violation then
    -- L'indice parziale qui sopra: c'e' gia' un import in corso. Esito, non errore — il client
    -- deve poter dire "ce n'e' uno in corso" senza interpretare un 23505.
    return jsonb_build_object('ok', false, 'reason', 'already_running');
  end;

  return jsonb_build_object('ok', true, 'job_id', v_job);
end;
$$;

comment on function public.create_import_job(text) is
  'SPEC v3 §7.2 fase 1: crea il job di import per il chiamante, sul proprio zip gia'' in '
  'Storage. Unica scrittura client su import_jobs; le fasi restano del server.';

-- Un job `failed` riparte. Non tocca `phase` ne' `checkpoint`: la fase in cui e' morto sa da
-- dove riprendere, ed e' tutto il punto di §7.2.
create or replace function public.retry_import_job(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
  v_count integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  begin
    update public.import_jobs
       set status = 'running', error = null
     where id = p_job_id
       and user_id = v_uid
       and status = 'failed';
    get diagnostics v_count = row_count;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'already_running');
  end;

  if v_count = 0 then
    -- Job altrui, inesistente o non fallito: per il chiamante e' la stessa risposta. Come per
    -- il login, distinguere sarebbe un oracolo su job che non gli appartengono.
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.retry_import_job(uuid) is
  'SPEC v3 §7.2: riporta a running un proprio job failed. Checkpoint e dedup_key rendono la '
  'ripresa sicura; non distingue "altrui" da "inesistente".';

-- L'impersonazione per la fase 4, e per lei sola. `set_config(..., true)` e' locale alla
-- transazione: quando la RPC torna, l'identita' e' gia' svanita. Si impostano entrambe le GUC
-- perche' `auth.uid()` legge `request.jwt.claims` in produzione e `request.jwt.claim.sub` nel
-- harness dei test (e nelle installazioni piu' vecchie): una sola delle due sarebbe giusta in
-- un posto e silenziosamente nulla nell'altro.
create or replace function public.import_apply_mutations(p_user uuid, batch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user is null then
    -- Errcode proprio, non il P0001 generico: P0001 e' il codice con cui falliscono le
    -- asserzioni dei test, e un rifiuto che lo condivide non si puo' testare con t.rejects.
    raise exception 'import_apply_mutations: p_user obbligatorio'
      using errcode = '22023'; -- invalid_parameter_value
  end if;

  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user::text, 'role', 'authenticated')::text,
                     true);

  perform public.apply_mutations(batch);
end;
$$;

comment on function public.import_apply_mutations(uuid, jsonb) is
  'SPEC v3 §7.2: apply_mutations con l''identita'' del proprietario del job, per il driver '
  'dell''import (fase 4 ad app chiusa). Eseguibile solo da service_role: fa fede proacl.';

-- I soliti DUE revoke (PUBLIC *e* i ruoli client: i default privileges di Supabase concedono
-- EXECUTE esplicito ad anon/authenticated alla creazione), poi i grant minimi.
revoke all on function public.create_import_job(text)            from public, anon;
revoke all on function public.retry_import_job(uuid)             from public, anon;
revoke all on function public.import_apply_mutations(uuid, jsonb) from public, anon, authenticated;

grant execute on function public.create_import_job(text)  to authenticated;
grant execute on function public.retry_import_job(uuid)   to authenticated;
grant execute on function public.import_apply_mutations(uuid, jsonb) to service_role;
