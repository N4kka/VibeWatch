-- F0.b.3 — public_profiles era una vista SECURITY DEFINER (unico ERROR degli
-- advisor): aggirava la RLS di profiles. L'ordine qui e' vincolante — prima la
-- policy, poi security_invoker. Invertirlo svuota la vista in silenzio e manda
-- a schermo bianco i profili pubblici e la ricerca utenti su iOS.
--
-- NOTA: questa migration e' stata annullata subito dopo da
-- 20260814071101_f0b_revert_public_profiles_security_invoker.sql — vedi li' il
-- motivo (esposizione di profiles.email / profiles.fcm_token). Resta a
-- history perche' e' stata effettivamente applicata in produzione.

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

-- Guardia: se la vista non restituisce piu' le stesse 305 righe viste da anon,
-- l'intera migration va in rollback.
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
