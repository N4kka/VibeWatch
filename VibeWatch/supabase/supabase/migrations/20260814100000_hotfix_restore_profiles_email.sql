-- HOTFIX — ripristino di profiles.email. Il login era rotto per tutti i metodi.
--
-- COSA HO SBAGLIATO. Prima di droppare `profiles.email` ho verificato chi la
-- LEGGE (un solo lettore, login-with-username, spostato su resolve_login_email).
-- Non ho verificato chi la SCRIVE. La scrive il client iOS, in due punti:
--
--   AuthService.swift:1156  updateUserProfileDirectly  -> upsert {id, email, ...}
--   AuthService.swift:1218  updateDisplayNameFromMetadata -> upsert {id, email, ...}
--
-- Il primo `throw`, e sta sul percorso di accesso di OGNI metodo di login. Con la
-- colonna assente PostgREST rifiuta l'intero payload (PGRST204, "Could not find
-- the 'email' column"), l'errore risale, e il login fallisce — username, Google
-- e Apple insieme. Ecco perché erano rotti tutti e tre e non solo lo username.
--
-- La premessa del piano — "il pull iOS fa SELECT * e tollera una colonna che
-- sparisce" — vale solo per le LETTURE. Un upsert con elenco esplicito di colonne
-- non tollera niente: è lo stesso identico motivo per cui il piano stesso teneva
-- `user_notification_preferences.list_milestone` e `.price_drop`. Avevo il
-- precedente davanti e non l'ho applicato qui.
--
-- Conseguenza: `public_profiles` torna SECURITY DEFINER. Con `email` di nuovo su
-- profiles, la policy larga necessaria a security_invoker la esporrebbe a tutti,
-- ed è esattamente la ragione per cui avevo già annullato il primo tentativo.
-- L'ERROR dell'advisor su quella vista resta: è un lint, e qui la vista definer è
-- il pattern corretto — una proiezione di 6 colonne sicure. Il vero fix è togliere
-- `email` da profiles, ma richiede una release iOS che non la scriva più: gated v2.9.

-- Prima l'invoker, poi la policy: al contrario la vista resterebbe senza righe.
ALTER VIEW public.public_profiles SET (security_invoker = off);
DROP POLICY IF EXISTS profiles_select_public ON public.profiles;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS email text;

-- auth.users è e resta la fonte: questa è una copia, e la si riallinea da lì.
UPDATE public.profiles p
   SET email = u.email
  FROM auth.users u
 WHERE u.id = p.id
   AND p.email IS DISTINCT FROM u.email;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  INSERT INTO public.profiles (
    id,
    email,
    display_name,
    avatar_url,
    created_at,
    updated_at
  )
  VALUES (
    new.id,
    new.email,
    COALESCE(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = EXCLUDED.email,
    display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
    avatar_url = COALESCE(EXCLUDED.avatar_url, public.profiles.avatar_url),
    updated_at = NOW();

  RETURN new;
END;
$function$;

-- resolve_login_email resta: legge da auth.users, funziona in entrambi i mondi,
-- ed è comunque la fonte giusta. login-with-username non va ritoccata.

DO $$
DECLARE mancanti integer; n integer;
BEGIN
  SELECT count(*) INTO mancanti
    FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE p.email IS DISTINCT FROM u.email;
  IF mancanti > 0 THEN
    RAISE EXCEPTION '% profili con email non allineata ad auth.users — rollback', mancanti;
  END IF;

  SELECT count(*) INTO n FROM public.public_profiles;
  IF n <> 305 THEN
    RAISE EXCEPTION 'public_profiles = % righe, attese 305 — rollback', n;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
