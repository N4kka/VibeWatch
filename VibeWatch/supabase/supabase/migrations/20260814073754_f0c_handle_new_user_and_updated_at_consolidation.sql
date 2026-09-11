-- F0.c.6 — handle_new_user non deve piu' scrivere le colonne che F0.d.1 elimina
-- (daily_clips_watched, is_founding_member). Il resto del corpo resta identico,
-- ON CONFLICT compreso.
--
-- Nota: contrariamente a quanto diceva il piano, questa funzione NON semina gli
-- username — l'unico trigger su auth.users e' questo, e non li tocca. Il seeding
-- passa da set_username / backfill. Nessuna regressione possibile qui.
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

-- F0.c.7 — tre funzioni trigger copia-carbone per lo stesso updated_at.
-- set_clips_updated_at usava timezone('utc', now()), le altre now(): su colonne
-- timestamptz e con TimeZone del database a UTC le due forme coincidono
-- (verificato: now() = timezone('utc', now()) e tutte e sei le colonne coinvolte
-- sono `timestamp with time zone`). Sopravvive set_updated_at.

DROP TRIGGER trg_clips_updated_at ON public.clips;
CREATE TRIGGER trg_clips_updated_at
  BEFORE UPDATE ON public.clips
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER update_filters_updated_at ON public.global_discovery_filters;
CREATE TRIGGER update_filters_updated_at
  BEFORE UPDATE ON public.global_discovery_filters
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER update_unified_prefs_updated_at ON public.unified_user_preferences;
CREATE TRIGGER update_unified_prefs_updated_at
  BEFORE UPDATE ON public.unified_user_preferences
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Senza CASCADE: se qualcosa dipendesse ancora da queste due, la migration
-- deve fallire invece di portarselo via in silenzio.
DROP FUNCTION public.update_updated_at_column();
DROP FUNCTION public.set_clips_updated_at();

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE ns.nspname = 'public' AND NOT t.tgisinternal
    AND p.proname = 'set_updated_at';
  IF n <> 6 THEN
    RAISE EXCEPTION 'attesi 6 trigger su set_updated_at, trovati % — rollback', n;
  END IF;
END $$;
