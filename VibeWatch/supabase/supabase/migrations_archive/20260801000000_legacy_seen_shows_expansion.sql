-- SPEC v3 §12 blocco 7 — la migrazione dello storico di chi usa gia' VibeWatch.
--
-- **Perche' serve.** La schermata Tracking legge `watch_events`. Per chi arriva da TV Time quella
-- tabella la riempie l'import (§7.2); per chi usa VibeWatch da prima non la riempie nessuno, e la
-- schermata e' vuota — dati intatti nel vecchio sistema, invisibili nel nuovo. Il grosso della
-- migrazione lo fa il client: le chiavi `"{showId}_{season}_{episode}"` di `EpisodeSeenManager`
-- sono gia' coppie (stagione, episodio) e vanno in `apply_mutations` cosi' come sono.
--
-- **Cosa il client non puo' fare, ed e' il motivo per cui questa funzione esiste.** Una serie
-- marcata "vista per intero" (`seenShowIds`, o l'aggiunta alla lista `seen`) non dice *quali*
-- episodi: dice solo che non ne manca nessuno. Espanderla richiede il catalogo, che vive qui
-- (§1.4) e che il client non ha e non deve avere. L'alternativa — scrivere il solo `user_status` e
-- lasciare `watched_count` a zero — mette una serie finita nel bucket `not_started`, cioe' fra le
-- serie "da iniziare": e' esattamente il tipo di bugia silenziosa che questa spec cerca di togliere.
--
-- **Cosa NON si inventa.**
--   * `watched_at_precision = 'inferred'`, mai `exact`: la data di visione vera non esiste da
--     nessuna parte in UserDefaults, e §3.2 esiste per tenere separato cio' che si sa da cio' che
--     si e' dedotto. Le statistiche temporali potranno escludere queste righe.
--   * si marcano solo gli episodi **gia' usciti**: "l'ho visto tutto" non e' una previsione, e un
--     episodio futuro marcato visto renderebbe la serie in pari per sempre.
--   * gli speciali restano fuori (§1.3) a meno che l'utente non li conti nel progresso —
--     `user_counts_specials`, la stessa preferenza che usa `recompute_tv_show_state`. Se le due
--     leggessero criteri diversi, "in pari" qui e "in pari" li' vorrebbero dire cose diverse.
--
-- **Idempotenza.** `dedup_key = 'legacy:{show}:{season}:{episode}'`, la stessa forma che usa il
-- client per gli episodi singoli: rigiocare la migrazione non duplica niente (criterio 2 di §13),
-- e una serie meta' migrata dal client e meta' espansa qui converge sulla stessa chiave.
--
-- **Perche' `security definer`, e perche' non e' un IDOR.** La funzione legge
-- `user_counts_specials`, che al client non e' chiamabile apposta (verificato nel test): invoker
-- fallirebbe sul permesso. Definer, pero', scavalca anche la RLS di `watch_events` — quindi il
-- punto che conta e' che **non esiste un parametro con l'identita'**: l'unico `user_id` in tutta
-- la funzione e' `auth.uid()`, e non c'e' niente che il chiamante possa passare per scrivere
-- altrove. L'IDOR di `import-parse` aveva la forma opposta: un id preso dalla richiesta e mai
-- confrontato.

create or replace function public.expand_seen_shows_to_watch_events(p_shows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_today     date;
  v_specials  boolean;
  v_written   integer := 0;
  v_no_catalog integer[] := '{}';
  r           record;
  v_rows      integer;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  if jsonb_typeof(p_shows) is distinct from 'array' then
    raise exception 'p_shows must be a json array of {tmdb_show_id, watched_at}';
  end if;

  -- Il fuso dell'utente, non quello del server: a UTC+14 `current_date` e' ieri, e un episodio
  -- uscito oggi resterebbe fuori dall'espansione per 24 ore (§3.3, limite noto).
  v_today    := public.user_today(v_uid);
  v_specials := public.user_counts_specials(v_uid);

  for r in
    select
      (e->>'tmdb_show_id')::integer as show_id,
      coalesce((e->>'watched_at')::timestamptz, now()) as watched_at
    from jsonb_array_elements(p_shows) as e
    where (e->>'tmdb_show_id') is not null
  loop
    -- Una serie il cui catalogo non e' ancora stato risolto non si espande: senza episodi non c'e'
    -- niente da scrivere, e scrivere "zero episodi visti" sarebbe indistinguibile da "non l'ho mai
    -- iniziata". Torna al chiamante nell'elenco, che sa che deve prima riscaldare il catalogo.
    if not exists (select 1 from public.tmdb_episodes c where c.tmdb_show_id = r.show_id) then
      v_no_catalog := v_no_catalog || r.show_id;
      continue;
    end if;

    insert into public.watch_events
      (user_id, media_type, tmdb_show_id, season_number, episode_number,
       watched_at, watched_at_precision, runtime_seconds, is_special,
       source, external_ref, dedup_key)
    select
      v_uid, 'tv', c.tmdb_show_id, c.season_number, c.episode_number,
      r.watched_at, 'inferred', c.runtime_minutes * 60,
      public.is_special_episode(c.season_number),
      'import_other',
      jsonb_build_object('legacy_origin', 'seen_show'),
      'legacy:' || c.tmdb_show_id || ':' || c.season_number || ':' || c.episode_number
    from public.tmdb_episodes c
    where c.tmdb_show_id = r.show_id
      and (v_specials or not public.is_special_episode(c.season_number))
      and c.air_date is not null
      and c.air_date <= v_today
      -- La dedup si fa qui e non lasciando esplodere l'indice unico, per la stessa ragione per cui
      -- la fa `apply_mutations`: un rigioco e' un caso normale, non un errore da registrare.
      and not exists (
        select 1 from public.watch_events d
        where d.user_id = v_uid
          and d.dedup_key = 'legacy:' || c.tmdb_show_id || ':' || c.season_number || ':' || c.episode_number
          and d.deleted_at is null
      );

    get diagnostics v_rows = row_count;
    v_written := v_written + v_rows;
  end loop;

  return jsonb_build_object(
    'events_written', v_written,
    'shows_without_catalog', to_jsonb(v_no_catalog)
  );
end $$;

comment on function public.expand_seen_shows_to_watch_events(jsonb) is
  'SPEC v3 blocco 7: espande "serie vista per intero" negli episodi gia'' usciti che il catalogo '
  'conosce. Precision inferred, dedup_key legacy:*, rigiocabile.';

-- I revoke vanno fatti a PUBLIC **e** ai due ruoli client: Supabase ha un
-- `alter default privileges` che concede EXECUTE ad anon/authenticated in modo esplicito, e
-- revocare al solo PUBLIC non toglie i grant espliciti — `has_function_privilege` continua a
-- rispondere true. Il controllo che vale e' `proacl`, non il revoke che si e' scritto.
revoke all on function public.expand_seen_shows_to_watch_events(jsonb) from public;
revoke all on function public.expand_seen_shows_to_watch_events(jsonb) from anon;
revoke all on function public.expand_seen_shows_to_watch_events(jsonb) from authenticated;
grant execute on function public.expand_seen_shows_to_watch_events(jsonb) to authenticated;
