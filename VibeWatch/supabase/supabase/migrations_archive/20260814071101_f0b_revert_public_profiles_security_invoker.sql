-- Rollback di f0b_public_profiles_security_invoker.
--
-- Il piano chiedeva security_invoker=on + una policy SELECT larga su profiles.
-- Ma profiles contiene `email` e `fcm_token`, e la policy le rende leggibili
-- via GET /rest/v1/profiles?select=email a chiunque — anon incluso — per tutti
-- i 305 profili pubblici. La vista public_profiles esclude l'email di proposito
-- (cfr. il commento in supabase/functions/login-with-username/index.ts).
--
-- Con select("*") usato dal pull iOS su profiles (SyncEngine.swift:930) i grant
-- per-colonna non sono una via d'uscita per il ruolo authenticated.
--
-- Si torna alla vista SECURITY DEFINER, che qui e' il pattern corretto (una
-- proiezione controllata di 6 colonne sicure). L'ERROR dell'advisor si chiudera'
-- dopo aver tolto le colonne sensibili da profiles (F0.d + spostamento di email).
--
-- L'ordine e' l'inverso della creazione: prima si toglie l'invoker, poi la
-- policy, cosi' la vista non resta mai senza righe.

ALTER VIEW public.public_profiles SET (security_invoker = off);
DROP POLICY IF EXISTS profiles_select_public ON public.profiles;

DO $$
DECLARE n integer;
BEGIN
  SET LOCAL ROLE anon;
  SELECT count(*) INTO n FROM public.public_profiles;
  RESET ROLE;
  IF n <> 305 THEN
    RAISE EXCEPTION 'public_profiles come anon = %, attese 305 righe — rollback', n;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
