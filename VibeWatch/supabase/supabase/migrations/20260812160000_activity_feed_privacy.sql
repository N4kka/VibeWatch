-- Social feed M1 — il consenso: `activity_feed_enabled` + `feed_activated_at`.
--
-- Il feed è pubblico di default, ma il backfill è storia scritta PRIMA che il feed esistesse:
-- pubblicarla in silenzio non si fa. `feed_activated_at` è il cancello: finché è null — cioè
-- finché l'utente non ha visto l'annuncio e scelto — le sue attività non compaiono a nessuno,
-- backfill incluso. Entrambe le scelte dell'annuncio ("attiva il feed" / "resta privato")
-- stampano l'attivazione: la domanda si fa una volta sola, e da lì in poi comanda il toggle
-- `activity_feed_enabled` nei settings.
--
-- Due colonne su `profiles` e non una tabella nuova: è esattamente il posto di
-- `is_profile_public`, la stessa famiglia di scelte, e il pull di `profiles` le porta al
-- client gratis.

alter table public.profiles
  add column if not exists activity_feed_enabled boolean not null default true,
  add column if not exists feed_activated_at timestamptz;

comment on column public.profiles.activity_feed_enabled is
  'Social feed M1: toggle "le mie attivita'' nel feed". Default true, ma non fa fede da solo: '
  'serve anche feed_activated_at non-null (il consenso esplicito).';
comment on column public.profiles.feed_activated_at is
  'Social feed M1: quando l''utente ha risposto all''annuncio del feed (in qualunque modo). '
  'Null = mai risposto = invisibile nel feed, backfill incluso. Si stampa una volta, mai si azzera.';

-- Definer con identità auth.uid(), come set_username: nessun parametro porta l'identità.
create or replace function public.set_activity_feed_visibility(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'unauthenticated';
  end if;
  update public.profiles
     set activity_feed_enabled = coalesce(p_enabled, true),
         feed_activated_at = coalesce(feed_activated_at, now()),
         updated_at = now()
   where id = (select auth.uid());
end $$;

comment on function public.set_activity_feed_visibility(boolean) is
  'Social feed M1: risponde all''annuncio o muove il toggle nei settings. Stampa '
  'feed_activated_at la prima volta e non lo azzera mai: il consenso e'' un fatto, non uno stato.';

revoke all on function public.set_activity_feed_visibility(boolean) from public;
revoke all on function public.set_activity_feed_visibility(boolean) from anon;
revoke all on function public.set_activity_feed_visibility(boolean) from authenticated;
grant execute on function public.set_activity_feed_visibility(boolean) to authenticated;
