-- F0.b.3, secondo tentativo — questa volta in sicurezza.
--
-- Il primo tentativo (20260814070834, annullato da 20260814071101) rendeva
-- public_profiles una vista security_invoker aggiungendo una policy SELECT larga
-- su profiles. Quella policy esponeva pero' TUTTE le colonne della riga, e
-- profiles conteneva `email` e `fcm_token`: gli indirizzi dei 305 profili
-- pubblici sarebbero stati leggibili via GET /rest/v1/profiles?select=email da
-- chiunque, anon compreso. I grant per-colonna non erano una via d'uscita perche'
-- il pull iOS fa `select("*")` su profiles (SyncEngine.swift:930).
--
-- Ora quelle colonne non ci sono piu':
--   * fcm_token e le altre 10 sono uscite con F0.d.1 (sostituite da user_devices);
--   * `email` esce qui — l'unico lettore, login-with-username, e' gia' passato a
--     resolve_login_email(), che la prende da auth.users. E' comunque una
--     duplicazione: auth.users e' la fonte, e le funzioni che mandano mail
--     leggevano gia' da li' con auth.admin.getUserById.
--
-- Restano le 14 colonne del profilo, tutte gia' pubbliche o innocue.

-- handle_new_user non deve piu' scrivere una colonna che sta per sparire.
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  INSERT INTO public.profiles (
    id,
    display_name,
    avatar_url,
    created_at,
    updated_at
  )
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO UPDATE
  SET
    display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
    avatar_url = COALESCE(EXCLUDED.avatar_url, public.profiles.avatar_url),
    updated_at = NOW();

  RETURN new;
END;
$function$;

ALTER TABLE public.profiles DROP COLUMN email;

-- Ora l'ordine vincolante: PRIMA la policy, POI security_invoker.
-- Invertirlo svuota la vista in silenzio e manda a schermo bianco i profili
-- pubblici e la ricerca utenti su iOS.
CREATE POLICY profiles_select_public
  ON public.profiles
  FOR SELECT
  TO anon, authenticated
  USING (
    deleted_at IS NULL
    AND is_profile_public
    AND username IS NOT NULL
  );

ALTER VIEW public.public_profiles SET (security_invoker = on);

-- Le tre viste-guscio non hanno una tabella sotto (sono `SELECT NULL ... WHERE
-- false`): l'invoker non cambia cosa restituiscono — sempre zero righe — ma
-- toglie tre ERROR dagli advisor che qui non significano nulla.
ALTER VIEW public.user_preferences  SET (security_invoker = on);
ALTER VIEW public.user_clip_history SET (security_invoker = on);
ALTER VIEW public.device_info       SET (security_invoker = on);

-- movie_reaction_counts resta DEFINER di proposito: la RLS di movie_reactions e'
-- per-proprietario e l'invoker trasformerebbe il contatore globale in personale.

DO $$
DECLARE n integer; leaked integer; ruolo text := current_user;
BEGIN
  -- Non `RESET ROLE`: quello torna al ruolo di sessione, che con la connessione
  -- della CLI non e' quello privilegiato che sta applicando la migration — e il
  -- push fallisce dopo, sull'insert nella tabella di history. Si rimette
  -- esattamente il ruolo di partenza.
  SET LOCAL ROLE anon;
  SELECT count(*) INTO n FROM public.public_profiles;
  EXECUTE format('SET LOCAL ROLE %I', ruolo);
  IF n <> 305 THEN
    RAISE EXCEPTION 'public_profiles come anon = %, attese 305 righe — rollback', n;
  END IF;

  -- E la ragione del primo rollback non deve poter tornare: nessuna colonna
  -- sensibile residua su profiles.
  SELECT count(*) INTO leaked FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'profiles'
     AND column_name IN ('email','fcm_token');
  IF leaked > 0 THEN
    RAISE EXCEPTION 'profiles espone ancora % colonne sensibili — rollback', leaked;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
