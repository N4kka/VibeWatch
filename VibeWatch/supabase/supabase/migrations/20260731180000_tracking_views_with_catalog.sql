-- SPEC v3 §9.2 / §13.6 — le viste che la schermata Tracking legge, catalogo incluso.
--
-- Il requisito e' netto: "la schermata deve renderizzare da cache locale, zero chiamate di rete,
-- in meno di 300 ms. Se serve rete per mostrare la lista, il lavoro e' sbagliato."
--
-- `tv_show_state` da sola non basta: ha i contatori e il prossimo episodio, ma non il nome della
-- serie, il poster, ne' il titolo dell'episodio. Prenderli separatamente vorrebbe dire mirrorare
-- in locale anche `tmdb_shows` e `tmdb_episodes` — che NON sono user-scoped, quindi fuori dal
-- percorso di pull esistente — e poi ricomporli nel client. Ricomporli nel client e' esattamente
-- cio' che §1.1 toglie di mezzo: il client legge lo stato derivato, non lo ricalcola.
--
-- Quindi la giunzione si fa qui, una volta, e il client ritira righe gia' pronte per la schermata.
-- Costo: una riga per serie seguita (430 nel caso peggiore misurato), qualche decina di KB.
--
-- `security_invoker = on` su entrambe: senza, una vista di proprieta' di `postgres` scavalcherebbe
-- la RLS di `tv_show_state` e ogni utente vedrebbe il tracking di tutti. E' gia' com'era impostata
-- `v_tv_tracking` e va mantenuto.

create or replace view public.v_tv_tracking with (security_invoker = on) as
select
  s.user_id,
  s.tmdb_show_id,
  s.user_status,
  s.watched_count,
  s.aired_count,
  s.total_count,
  s.last_watched_at,
  s.next_season,
  s.next_episode,
  s.next_air_date,
  s.backlog_since,
  s.first_watched_at,
  s.completed_at,
  s.updated_at,
  s.synced_at,
  public.tv_tracking_bucket(s.user_status, s.watched_count, s.backlog_since) as bucket,
  s.next_air_date is not null
    and s.next_air_date <= public.user_today(s.user_id) as is_next_available,
  -- Da qui in poi e' il catalogo: cio' che serve a disegnare la card senza toccare la rete.
  sh.name            as show_name,
  sh.poster_path     as show_poster_path,
  sh.status          as show_status,
  ne.name            as next_episode_name,
  ne.still_path      as next_still_path,
  ne.runtime_minutes as next_runtime_minutes
from public.tv_show_state s
-- LEFT e non INNER: una serie tracciata il cui catalogo non e' ancora stato risolto deve
-- comparire lo stesso, con il nome vuoto, invece di sparire dalla lista dell'utente.
left join public.tmdb_shows sh
  on sh.tmdb_show_id = s.tmdb_show_id
left join public.tmdb_episodes ne
  on  ne.tmdb_show_id  = s.tmdb_show_id
  and ne.season_number = s.next_season
  and ne.episode_number = s.next_episode;

comment on view public.v_tv_tracking is
  'SPEC v3 §9.2: una riga per serie seguita, gia'' pronta per la card — stato derivato dal server '
  '(§1.1) piu'' i campi di catalogo, cosi'' il client non deve ricomporre niente.';

-- La "Timeline uscite" di §9.2: i prossimi episodi delle serie attive, 30 giorni avanti.
--
-- Gli speciali ci sono e sono marcati, non filtrati: §1.3 si intitola proprio cosi'. Un episodio
-- speciale non entra nel *progresso*, ma resta un'uscita che l'utente puo' voler vedere, e la
-- decisione se mostrarlo tocca alla UI, non a questa vista.
--
-- Il limite di giorni e' dentro la vista e non nel client per lo stesso motivo di sempre: se lo
-- decidesse il client, il giorno che cambia idea servirebbe una nuova app su tutti i telefoni.
create or replace view public.v_tv_timeline with (security_invoker = on) as
select
  -- Chiave stabile per il mirror locale e per la paginazione del pull: la timeline non ha una
  -- colonna unica sua, e paginare senza un ordinamento unico fa saltare e ripetere righe
  -- contemporaneamente (la lezione di §5, gia' pagata una volta).
  e.tmdb_show_id || ':' || e.season_number || ':' || e.episode_number as id,
  s.user_id,
  e.tmdb_show_id,
  sh.name        as show_name,
  sh.poster_path as show_poster_path,
  e.season_number,
  e.episode_number,
  e.name         as episode_name,
  e.air_date,
  e.still_path,
  public.is_special_episode(e.season_number) as is_special
from public.tv_show_state s
join public.tmdb_episodes e on e.tmdb_show_id = s.tmdb_show_id
left join public.tmdb_shows sh on sh.tmdb_show_id = s.tmdb_show_id
where s.user_status = 'active'
  and e.air_date is not null
  -- `user_today` e non `current_date`: il job gira in UTC ma l'utente no, e a UTC+14 un episodio
  -- di oggi sarebbe classificato come futuro fino a mezzanotte UTC (§3.3, limite noto).
  and e.air_date >= public.user_today(s.user_id)
  and e.air_date <= public.user_today(s.user_id) + 30;

comment on view public.v_tv_timeline is
  'SPEC v3 §9.2: le uscite dei prossimi 30 giorni per le serie attive. Gli speciali ci sono e '
  'sono marcati (§1.3), la scelta se mostrarli e'' della UI.';

-- Le due viste sono `security_invoker`, quindi la RLS di `tv_show_state` fa da filtro e questi
-- grant non aprono niente che non fosse gia' aperto. Ad `anon` non servono comunque.
revoke all on public.v_tv_tracking from anon;
revoke all on public.v_tv_timeline  from anon;
grant select on public.v_tv_tracking to authenticated;
grant select on public.v_tv_timeline  to authenticated;
