-- GDPR (audit §3b): `delete-user` cancellava le tabelle ma NON gli oggetti Storage — gli ZIP
-- GDPR in `imports/{user_id}/…` (dati personali di terzi, §7.2) e gli avatar (riconoscibili
-- solo dall'`owner`: il nome del file usa uuid di device, non l'id auth).
--
-- Questa funzione ELENCA e basta, come `imports_stale_uploads`: la cancellazione la fa la
-- Edge Function via Storage API — mai DELETE su `storage.objects`, che lascerebbe i byte
-- orfani nel bucket S3 sottostante.
--
-- Service-only: prende un utente arbitrario, e in mano a un client sarebbe un inventario
-- dei file altrui. `proacl` fa fede (lezione di `import_touched_shows`).

create or replace function public.user_storage_objects(p_user uuid)
returns table (bucket_id text, name text)
language sql
stable
security definer
set search_path = public, storage
as $$
  select o.bucket_id, o.name
    from storage.objects o
   where o.owner = p_user
      -- Gli ZIP dell'import stanno nella cartella dell'utente anche se l'owner un giorno
      -- cambiasse forma: il percorso è il contratto delle policy del bucket.
      or (o.bucket_id = 'imports' and o.name like p_user::text || '/%');
$$;

comment on function public.user_storage_objects(uuid) is
  'GDPR: gli oggetti Storage di un utente (owner, piu'' la cartella imports/{id}). Elenca '
  'soltanto: cancella la Edge Function delete-user via Storage API. Solo service_role.';

revoke all on function public.user_storage_objects(uuid) from public, anon, authenticated;
grant execute on function public.user_storage_objects(uuid) to service_role;
