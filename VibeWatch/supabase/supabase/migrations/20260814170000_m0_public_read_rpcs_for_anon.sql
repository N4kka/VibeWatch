-- M0 — le RPC di lettura pubblica servono anche ad `anon`, per il SSR del web.
--
-- Le rotte pubbliche del piano (`/@:username`, `/list/:id`) vengono renderizzate
-- lato server con il client anonimo, perche' devono finire nell'anteprima di un
-- link e nei motori di ricerca: a quel punto non c'e' nessuna sessione. Oggi
-- quelle tre RPC sono concesse solo ad `authenticated`, quindi il SSR
-- riceverebbe "permission denied" — verificato provando davvero come anon.
--
-- Nessuna delle tre espone piu' di quanto `public_profiles` gia' mostri ad anon,
-- e per un chiamante senza sessione i rami basati su auth.uid() si chiudono da
-- soli invece di aprirsi:
--
--   get_public_profile          legge solo da public_profiles; is_following e
--                               follows_me diventano false; i preferiti sono
--                               soltanto slot + tmdb_id, senza titoli.
--   get_public_lists            filtra `l.is_public`; per anon la scorciatoia
--                               "sono io il proprietario" non scatta, quindi la
--                               soglia delle 3 segnalazioni vale sempre — piu'
--                               restrittivo che per un utente loggato, non meno.
--   get_list_items_with_providers  stessa struttura: senza sessione resta solo
--                               il ramo pubblico, con is_public + blocchi +
--                               soglia segnalazioni.
--
-- `search_users` NON viene concessa ad anon di proposito: enumerare gli utenti
-- non serve a nessuna rotta pubblica, e da anonimo sarebbe uno strumento di
-- raccolta.
GRANT EXECUTE ON FUNCTION public.get_public_profile(text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_public_lists(text, text, integer, integer, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_list_items_with_providers(uuid, text) TO anon;

DO $$
DECLARE ruolo text := current_user; uname text; j jsonb; n integer;
BEGIN
  SELECT username INTO uname FROM public.public_profiles LIMIT 1;

  SET LOCAL ROLE anon;
  j := public.get_public_profile(uname);
  IF coalesce((j->>'found')::boolean, false) IS NOT TRUE THEN
    EXECUTE format('SET LOCAL ROLE %I', ruolo);
    RAISE EXCEPTION 'get_public_profile non trova % come anon — rollback', uname;
  END IF;
  IF j ? 'email' THEN
    EXECUTE format('SET LOCAL ROLE %I', ruolo);
    RAISE EXCEPTION 'get_public_profile espone email ad anon — rollback';
  END IF;

  SELECT count(*) INTO n FROM public.get_public_lists(null, 'explore', 5, 0, null);
  EXECUTE format('SET LOCAL ROLE %I', ruolo);
  RAISE NOTICE 'anon: profilo pubblico OK, % liste pubbliche', n;
END $$;
