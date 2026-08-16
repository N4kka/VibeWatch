-- F0.e — performance.

-- 1. Le 7 chiavi esterne delle tabelle social senza indice di copertura. Senza,
--    ogni cancellazione del padre fa una scansione sequenziale del figlio, e le
--    query del feed che partono dal padre pure.
CREATE INDEX IF NOT EXISTS activities_list_id_idx              ON public.activities (list_id);
CREATE INDEX IF NOT EXISTS activities_review_id_idx            ON public.activities (review_id);
CREATE INDEX IF NOT EXISTS activity_comment_likes_user_id_idx  ON public.activity_comment_likes (user_id);
CREATE INDEX IF NOT EXISTS activity_comments_user_id_idx       ON public.activity_comments (user_id);
CREATE INDEX IF NOT EXISTS activity_comments_parent_id_idx     ON public.activity_comments (parent_id);
CREATE INDEX IF NOT EXISTS activity_likes_user_id_idx          ON public.activity_likes (user_id);
CREATE INDEX IF NOT EXISTS user_blocks_blocked_user_id_idx     ON public.user_blocks (blocked_user_id);

-- 2. Il pull di watch_events riscarica oggi tutte le ~109.000 righe a ogni sync.
--    Questo indice e' il prerequisito del pull incrementale previsto per la v2.9:
--    si crea adesso perche' e' additivo e non cambia nulla per i client attuali.
CREATE INDEX IF NOT EXISTS watch_events_user_id_synced_at_idx ON public.watch_events (user_id, synced_at);

-- 3. user_ratings non ha una chiave primaria. L'identita' resta la chiave
--    naturale (l'indice unico parziale sulle righe vive), ma una tabella senza PK
--    e' un problema per replica logica e strumenti di diagnostica.
--
--    Sicuro per apply_mutations: il suo ramo user_ratings elenca le colonne una
--    per una ("la chiave naturale, che non ha un id sintetico"), quindi `id`
--    prende il default e il client non lo vede mai. Il pull e' `select *`:
--    una colonna in piu' e' trasparente.
ALTER TABLE public.user_ratings ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.user_ratings ADD CONSTRAINT user_ratings_pkey PRIMARY KEY (id);

-- 4. Due indici mai usati da quando esistono (idx_scan = 0).
--    profiles_display_name_trgm: search_users cerca per username, non per
--    display_name. clips_updated_at_idx: nessuna query ordina o filtra li'.
--    idx_api_proxy_cache_expires resta invece: e' a 0 scansioni solo perche' il
--    cron di prune non era schedulato — da F0.c.4 lo e'.
DROP INDEX IF EXISTS public.profiles_display_name_trgm;
DROP INDEX IF EXISTS public.clips_updated_at_idx;
