-- I rifiuti `constraint_23505` su `lists` (10 occorrenze reali, 2 utenti) non erano un attacco
-- né un bug del server: erano il client che fa "ensure" delle liste di default con un INSERT.
--
-- La catena: quando una lista core (watchlist/seen/liked/disliked) manca in SQLite, il client ne
-- SINTETIZZA una con un UUID nuovo (`ensureCoreLists` → `defaultList(for:)`) e la accoda come
-- INSERT. L'upsert del ramo `lists` e' idempotente **su `id`**, ma il vincolo vero e' l'indice
-- parziale `idx_lists_one_active_default_per_user_type` su `(user_id, type)`: se il server ha
-- gia' una default di quel tipo con un ALTRO id, l'INSERT esplode 23505 e finisce in
-- `sync_rejected_mutations` — per un esito che in realta' e' CORRETTO: una default di quel tipo
-- esiste, che e' esattamente cio' che il client voleva garantire.
--
-- Qui il 23505 su QUELL'indice diventa uno skip silenziosamente riuscito, non un rifiuto:
-- l'intento "esista una default di questo tipo" e' gia' soddisfatto, e l'id canonico il client
-- lo adotta dal pull (`reconcileCoreListIdentities`). Ogni ALTRA violazione resta un rifiuto
-- registrato, come prima.
--
-- La modifica e' uno SPLICE sul `prosrc` reale (md5 verificato PRIMA: 54c9a84294e8e6a6e2dbfa09d2812566,
-- 32.191 caratteri), non una riscrittura dal file in cartella: e' la lezione dell'ordine delle
-- migration — i rami aggiunti per splice non stanno nell'ultimo file, e riscrivere da li' li
-- cancellerebbe in silenzio.
--
-- NB per il harness dei test: questa migration NON e' nella whitelist di `run.sh`, come le altre
-- che toccano `apply_mutations` — la funzione presuppone lo schema di produzione. Il collaudo e'
-- in produzione, dentro una transazione fatta fallire (zero residui).

-- L'indice su cui tutto si regge esiste in produzione ma non era in NESSUNA migration del repo:
-- lo si codifica qui, cosi' un database ricostruito da zero ha il vincolo su cui il ramo conta.
create unique index if not exists idx_lists_one_active_default_per_user_type
  on public.lists (user_id, type)
  where deleted_at is null and type in ('watchlist', 'seen', 'liked', 'disliked');

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

  -- Guardia: il prosrc reale, non "quello che il file in cartella dice che dovrebbe essere".
  if md5((select prosrc from pg_proc where proname = 'apply_mutations'
           and pronamespace = 'public'::regnamespace)) <> '54c9a84294e8e6a6e2dbfa09d2812566' then
    raise exception 'apply_mutations: prosrc diverso da quello verificato — splice rifiutato, ricontrollare a mano';
  end if;

  v_old := $old$      elsif tbl = 'lists' then
        if v_write then
          insert into public.lists as t
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
          where t.user_id = v_uid;
        elsif op = 'DELETE' then$old$;

  v_new := $new$      elsif tbl = 'lists' then
        if v_write then
          -- Una sola default ATTIVA per (user_id, type): l'INSERT che il client accoda per una
          -- lista core e' un "ensure", non una creazione. Se una default di quel tipo esiste
          -- gia' — con un ALTRO id, quindi invisibile all'upsert su (id) — l'intento e' gia'
          -- soddisfatto: rifiutare riempiva sync_rejected_mutations di constraint_23505 per un
          -- esito corretto. L'id canonico il client lo adotta dal pull. Ogni ALTRA violazione
          -- di unicita' resta un errore vero e risale al catch per-item.
          begin
            insert into public.lists as t
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
            where t.user_id = v_uid;
          exception when unique_violation then
            if sqlerrm not like '%idx_lists_one_active_default_per_user_type%' then
              raise;
            end if;
          end;
        elsif op = 'DELETE' then$new$;

  -- Il segmento va trovato ESATTAMENTE una volta: zero = prosrc cambiato sotto i piedi,
  -- piu' di una = lo splice riscriverebbe anche cio' che non deve.
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'apply_mutations: segmento lists non trovato o non unico — splice rifiutato';
  end if;

  execute replace(v_def, v_old, v_new);
end
$splice$;
