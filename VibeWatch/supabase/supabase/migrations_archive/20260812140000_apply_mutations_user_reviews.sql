-- Social feed M1 — `apply_mutations` impara `user_reviews`.
--
-- Senza questo ramo ogni review del client finirebbe in `table_not_handled`, cioe' in
-- `sync_rejected_mutations`: la perdita silenziosa di sempre.
--
-- **Id del client autoritativo, con bonifica della chiave naturale.** A differenza di
-- `user_ratings`, qui l'id sintetico esiste (i report e `activities.review_id` lo referenziano)
-- e lo genera il client. L'upsert e' quindi su (id) — ma l'indice unico parziale ammette una
-- sola review viva per titolo, e due dispositivi offline possono averne create due con id
-- diversi. Prima dell'upsert si mette la lapide a ogni ALTRA riga viva della stessa chiave
-- naturale: l'ultima scrittura vince (lastWriteWins, come da strategia), la lapide viaggia col
-- pull e l'altro dispositivo converge da solo. Mai lasciare che l'indice unico esploda: sarebbe
-- un rifiuto registrato per un caso che e' normale, non un errore.
--
-- **Perche' uno splice e non una riscrittura.** L'ultima versione integrale di `apply_mutations`
-- in cartella non e' la versione viva: i rami aggiunti dalle migration successive sono splice sul
-- `prosrc` reale (vedi 20260805110000), e ricopiare un file li cancellerebbe in silenzio.
-- Verificato PRIMA di scrivere questo file: prosrc live 33250 caratteri, md5 normalizzato
-- 0e9089c0767eb25efe0f20ff814e35e7, ancora unica sul ramo `user_gamification`.

do $splice$
declare
  v_def text;
  v_anchor text;
  v_branch text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.proname = 'apply_mutations' and p.pronamespace = 'public'::regnamespace;

  if v_def is null then
    raise exception 'apply_mutations non esiste: questa migration presuppone lo schema di produzione';
  end if;

  -- Gia' applicata: rigiocare la migration non deve rompersi.
  if position('user_reviews' in v_def) > 0 then
    raise notice 'apply_mutations conosce gia'' user_reviews: splice non necessario';
    return;
  end if;

  -- Il ramo nuovo si inserisce PRIMA del ramo gamification: un punto stabile, lontano dai rami
  -- che le altre migration ritoccano (lists, ratings).
  v_anchor := $a$      elsif tbl in ('user_gamification','xp_transactions') then$a$;

  v_branch := $b$      elsif tbl = 'user_reviews' then
        -- Social feed M1: review breve, id client autoritativo. La bonifica della chiave
        -- naturale sta nel commento di testa della migration 20260812140000.
        if v_write then
          if coalesce(btrim(rec->>'content'),'') = '' or coalesce(rec->>'media_type','') = ''
             or coalesce(rec->>'tmdb_id','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            update public.user_reviews set deleted_at = now(), synced_at = now()
            where user_id = v_uid
              and media_type = rec->>'media_type'
              and tmdb_id = (rec->>'tmdb_id')::integer
              and deleted_at is null
              and id <> (rec->>'id')::uuid;
            insert into public.user_reviews as t
              (id, user_id, media_type, tmdb_id, content, contains_spoilers,
               created_at, updated_at, deleted_at, synced_at)
            values
              ((rec->>'id')::uuid, v_uid, rec->>'media_type', (rec->>'tmdb_id')::integer,
               rec->>'content',
               coalesce((rec->>'contains_spoilers')::boolean, false),
               coalesce(nullif(rec->>'created_at','')::timestamptz, now()),
               coalesce(nullif(rec->>'updated_at','')::timestamptz, now()),
               nullif(rec->>'deleted_at','')::timestamptz, now())
            on conflict (id) do update set
              content = excluded.content,
              contains_spoilers = excluded.contains_spoilers,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          update public.user_reviews set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;

$b$;

  -- L'ancora va trovata ESATTAMENTE una volta: zero = prosrc cambiato sotto i piedi,
  -- piu' di una = lo splice riscriverebbe anche cio' che non deve.
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'apply_mutations: ancora gamification non trovata o non unica — splice rifiutato';
  end if;

  execute replace(v_def, v_anchor, v_branch || v_anchor);
end
$splice$;
