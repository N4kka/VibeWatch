-- La lista pubblica copiata segue la lista di origine (Task 11).
--
-- **Il difetto.** "Crea lista pubblica da questa" copia gli item una volta sola e poi taglia il
-- filo: aggiungere un titolo alla watchlist non lo fa comparire nella copia che gli amici
-- seguono, e la lista pubblica invecchia senza che nessuno se ne accorga.
--
-- **La cura.** Due colonne additive su `lists` che dicono da dove viene la copia. La propagazione
-- vera è client-side, nei due choke point `addToList`/`removeFromList` di `ListManager`: nessun
-- trigger, perché `get_public_lists` legge righe `list_items` reali — che è già esattamente ciò
-- che la copia contiene.
--
-- Limite accettato e documentato: si propagano le aggiunte e le rimozioni **esplicite**. Le
-- transizioni implicite del tracking (una serie che si completa da sola e passa da watchlist a
-- "viste") non toccano la copia.

alter table public.lists
  add column if not exists source_list_id uuid,
  add column if not exists source_list_type text
    check (source_list_type is null
           or source_list_type in ('watchlist','seen','liked','disliked'));

-- Il ramo `lists` di `apply_mutations` deve saper scrivere le due colonne, altrimenti il legame
-- vive solo su SQLite e sparisce al primo dispositivo nuovo.
--
-- **Perché uno splice e non una riscrittura.** L'ultima versione integrale di `apply_mutations`
-- in cartella non è la versione viva: i rami aggiunti dalle migration successive sono splice sul
-- `prosrc` reale (vedi 20260802200000), e ricopiare il file li cancellerebbe in silenzio. Si
-- cerca quindi il ramo `lists` così com'è oggi in produzione e si sostituisce quello.
do $splice$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.proname = 'apply_mutations' and p.pronamespace = 'public'::regnamespace;

  if v_def is null then
    raise exception 'apply_mutations non esiste: questa migration presuppone lo schema di produzione';
  end if;

  -- Già applicata: rigiocare la migration non deve rompersi.
  if position('source_list_id' in v_def) > 0 then
    raise notice 'apply_mutations conosce già source_list_id: splice non necessario';
    return;
  end if;

  v_old := $old$            insert into public.lists as t
              (id, user_id, name, description, type, is_public, created_at, updated_at, deleted_at, synced_at)
            values
              ((rec->>'id')::uuid, (rec->>'user_id')::uuid, rec->>'name', rec->>'description', rec->>'type',
               (coalesce((rec->>'is_public')::boolean, false) and (rec->>'type') = 'custom'),
               (rec->>'created_at')::timestamptz, (rec->>'updated_at')::timestamptz,
               (rec->>'deleted_at')::timestamptz, now())
            on conflict (id) do update set
              name = excluded.name,
              description = excluded.description,
              type = excluded.type,
              is_public = (coalesce((rec->>'is_public')::boolean, t.is_public) and excluded.type = 'custom'),
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;$old$;

  -- `nullif(...,'')::uuid`: il client manda stringa vuota dove non c'è legame, e '' non è un uuid.
  v_new := $new$            insert into public.lists as t
              (id, user_id, name, description, type, is_public, source_list_id, source_list_type,
               created_at, updated_at, deleted_at, synced_at)
            values
              ((rec->>'id')::uuid, (rec->>'user_id')::uuid, rec->>'name', rec->>'description', rec->>'type',
               (coalesce((rec->>'is_public')::boolean, false) and (rec->>'type') = 'custom'),
               nullif(rec->>'source_list_id', '')::uuid,
               nullif(rec->>'source_list_type', ''),
               (rec->>'created_at')::timestamptz, (rec->>'updated_at')::timestamptz,
               (rec->>'deleted_at')::timestamptz, now())
            on conflict (id) do update set
              name = excluded.name,
              description = excluded.description,
              type = excluded.type,
              is_public = (coalesce((rec->>'is_public')::boolean, t.is_public) and excluded.type = 'custom'),
              source_list_id = excluded.source_list_id,
              source_list_type = excluded.source_list_type,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;$new$;

  -- Il segmento va trovato ESATTAMENTE una volta: zero = prosrc cambiato sotto i piedi,
  -- più di una = lo splice riscriverebbe anche ciò che non deve.
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'apply_mutations: ramo lists non trovato o non unico — splice rifiutato';
  end if;

  execute replace(v_def, v_old, v_new);
end
$splice$;
