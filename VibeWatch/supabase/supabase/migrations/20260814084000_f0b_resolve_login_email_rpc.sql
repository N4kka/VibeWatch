-- Preparazione al drop di profiles.email (task F0.b.3-bis).
--
-- `profiles.email` ha un solo lettore in tutto il sistema: login-with-username,
-- che risolve username -> email per poi autenticare. Tutte le altre funzioni che
-- mandano email (email-digest, weekly-recap, process-notifications) prendono
-- l'indirizzo da `auth.users` via auth.admin.getUserById: la copia su profiles e'
-- una duplicazione, e finche' resta li' impedisce di rendere public_profiles una
-- vista security_invoker senza esporre gli indirizzi.
--
-- La risoluzione resta in UNA sola query, come prima. Non e' un dettaglio di
-- efficienza: login-with-username difende gli username da un oracolo di latenza
-- (commento in testa a quella funzione, difesa n. 2), e aggiungere un secondo
-- roundtrip solo per gli username esistenti avrebbe reintrodotto proprio quel
-- segnale.
CREATE OR REPLACE FUNCTION public.resolve_login_email(p_username text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT u.email::text
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE p.username = p_username
     AND p.deleted_at IS NULL
   LIMIT 1;
$function$;

-- Solo il service_role: esposta ai client sarebbe esattamente l'endpoint di
-- raccolta indirizzi che login-with-username esiste per evitare.
REVOKE ALL ON FUNCTION public.resolve_login_email(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_login_email(text) TO service_role;

COMMENT ON FUNCTION public.resolve_login_email(text) IS
  'username -> email da auth.users, per login-with-username. service_role soltanto: e'' un endpoint di harvesting se esposto ai client.';
