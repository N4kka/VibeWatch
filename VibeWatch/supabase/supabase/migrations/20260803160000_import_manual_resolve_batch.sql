-- SPEC v3 §7.4 — applicazione atomica di un batch di scelte manuali.
--
-- Tutte le mappe condivise, tutte le righe di staging e la singola riapertura del job sono una
-- decisione sola. Il checkpoint conserva una coda di contesti serie; import-resolve ne usa uno
-- per volta dentro lo stesso job, senza riavviare l'import per ogni titolo.

create or replace function public.import_reopen_manual_resolutions(
  p_job_id uuid,
  p_resolutions jsonb,
  p_row_indexes integer[],
  p_totals jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_affected integer;
  v_expected integer;
  v_unique_rows integer;
  v_resolution_count integer;
  v_unique_series integer;
  v_contexts jsonb;
  v_item record;
  v_tvdb_series_id bigint;
  v_tmdb_show_id integer;
  v_resolution text;
  v_existing_show integer;
  v_conflict_series bigint;
begin
  v_expected := cardinality(p_row_indexes);
  select count(distinct i)::integer into v_unique_rows
    from unnest(coalesce(p_row_indexes, array[]::integer[])) as u(i);

  if p_job_id is null
     or p_resolutions is null or jsonb_typeof(p_resolutions) <> 'array'
     or jsonb_array_length(p_resolutions) = 0
     or p_totals is null or jsonb_typeof(p_totals) <> 'object'
     or coalesce(v_expected, 0) = 0
     or v_unique_rows <> v_expected then
    return jsonb_build_object('ok', false, 'reason', 'invalid_plan');
  end if;

  -- Si valida prima di qualsiasi cast verso bigint/integer: anche un payload ostile con un
  -- numero enorme deve diventare `invalid_plan`, non un'eccezione fuori dalla transazione.
  if exists (
    select 1
      from jsonb_array_elements(p_resolutions) as r(value)
     where jsonb_typeof(value) <> 'object'
        or coalesce(value->>'tvdb_series_id', '') !~ '^[0-9]+$'
        or coalesce(value->>'tmdb_show_id', '') !~ '^[0-9]+$'
        or case when coalesce(value->>'tvdb_series_id', '') ~ '^[0-9]+$'
                then (value->>'tvdb_series_id')::numeric else 0 end
           not between 1 and 9223372036854775807
        or case when coalesce(value->>'tmdb_show_id', '') ~ '^[0-9]+$'
                then (value->>'tmdb_show_id')::numeric else 0 end
           not between 1 and 2147483647
  ) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_plan');
  end if;

  select count(*)::integer,
         count(distinct (value->>'tvdb_series_id')::bigint)::integer
    into v_resolution_count, v_unique_series
    from jsonb_array_elements(p_resolutions) as r(value);
  if v_resolution_count <> v_unique_series then
    return jsonb_build_object('ok', false, 'reason', 'invalid_plan');
  end if;

  select jsonb_agg(
           jsonb_build_object(
             'job_id', p_job_id,
             'tvdb_series_id', (value->>'tvdb_series_id')::bigint,
             'tmdb_show_id', (value->>'tmdb_show_id')::integer
           ) order by ord
         )
    into v_contexts
    from jsonb_array_elements(p_resolutions) with ordinality as r(value, ord);

  begin
    -- Questo UPDATE prende il lock sul job e fa scattare qui l'indice che ammette un solo job
    -- aperto per utente. Il blocco EXCEPTION è una subtransazione: qualsiasi conflitto rimette
    -- job, mappe e staging esattamente come prima.
    update public.import_jobs
       set phase = 'resolving',
           status = 'running',
           checkpoint = jsonb_build_object('manual_episode_contexts', v_contexts),
           totals = p_totals,
           error = null,
           locked_until = null
     where id = p_job_id
       and phase = 'done'
       and status = 'done';
    get diagnostics v_affected = row_count;
    if v_affected <> 1 then
      raise exception 'job non piu'' concluso' using errcode = 'VW001';
    end if;

    -- Ogni mappa viene inserita o promossa da non-finale a `found`. Una mappa `found` diversa
    -- non viene mai sovrascritta, neppure se un resolver concorrente vince mentre aspettiamo.
    for v_item in
      select value
        from jsonb_array_elements(p_resolutions) as r(value)
    loop
      v_tvdb_series_id := (v_item.value->>'tvdb_series_id')::bigint;
      v_tmdb_show_id := (v_item.value->>'tmdb_show_id')::integer;

      insert into public.tvdb_tmdb_map (
        tvdb_id, entity_type, tmdb_show_id, tmdb_movie_id,
        season_number, episode_number, resolution, method, resolved_at
      ) values (
        v_tvdb_series_id, 'series', v_tmdb_show_id, null,
        null, null, 'found', 'manual', now()
      )
      on conflict (tvdb_id, entity_type) do nothing;

      select resolution, tmdb_show_id
        into v_resolution, v_existing_show
        from public.tvdb_tmdb_map
       where tvdb_id = v_tvdb_series_id
         and entity_type = 'series'
       for update;

      if v_resolution = 'found' and v_existing_show <> v_tmdb_show_id then
        v_conflict_series := v_tvdb_series_id;
        raise exception 'serie gia'' mappata' using errcode = 'VW002';
      elsif v_resolution <> 'found' then
        update public.tvdb_tmdb_map
           set tmdb_show_id = v_tmdb_show_id,
               tmdb_movie_id = null,
               season_number = null,
               episode_number = null,
               resolution = 'found',
               method = 'manual',
               resolved_at = now()
         where tvdb_id = v_tvdb_series_id
           and entity_type = 'series';
      end if;
    end loop;

    -- Le righe catalogo devono appartenere a una serie scelta. Per un voto, che non porta una
    -- serie affidabile, l'episodio deve comparire in un evento selezionato e non avere una mappa
    -- `found` verso uno show diverso. Il conteggio rende atomico anche un cambiamento concorrente.
    update public.import_staging as target
       set resolved = null,
           status = 'pending',
           error = null
     where target.job_id = p_job_id
       and target.row_index = any(p_row_indexes)
       and (
         (
           target.status = 'unresolved'
           and target.error like 'catalogo:%'
           and target.raw->>'row_kind' in ('event', 'status', 'favorite')
           and exists (
             select 1
               from jsonb_array_elements(p_resolutions) as chosen(value)
              where chosen.value->>'tvdb_series_id' = target.raw->>'tvdb_series_id'
           )
         )
         or (
           target.status = 'skipped'
           and target.error = 'voti: non_risolto'
           and target.raw->>'row_kind' = 'rating'
           and exists (
             select 1
               from public.import_staging as event_row
               join jsonb_array_elements(p_resolutions) as chosen(value)
                 on chosen.value->>'tvdb_series_id' = event_row.raw->>'tvdb_series_id'
              where event_row.job_id = target.job_id
                and event_row.row_index = any(p_row_indexes)
                and event_row.raw->>'row_kind' = 'event'
                and event_row.raw->>'tvdb_episode_id' = target.raw->>'tvdb_episode_id'
                and not exists (
                  select 1
                    from public.tvdb_tmdb_map as episode_map
                   where episode_map.entity_type = 'episode'
                     and episode_map.tvdb_id::text = target.raw->>'tvdb_episode_id'
                     and episode_map.resolution = 'found'
                     and episode_map.tmdb_show_id is distinct from
                         (chosen.value->>'tmdb_show_id')::integer
                )
           )
         )
       );
    get diagnostics v_affected = row_count;
    if v_affected <> v_expected then
      raise exception 'staging cambiato durante la risoluzione' using errcode = 'VW003';
    end if;

    return jsonb_build_object('ok', true);
  exception
    when unique_violation then
      return jsonb_build_object('ok', false, 'reason', 'another_job_open');
    when sqlstate 'VW001' then
      return jsonb_build_object('ok', false, 'reason', 'job_not_done');
    when sqlstate 'VW002' then
      return jsonb_build_object(
        'ok', false,
        'reason', 'series_already_mapped',
        'tvdb_series_id', v_conflict_series,
        'tmdb_show_id', v_existing_show
      );
    when sqlstate 'VW003' then
      return jsonb_build_object('ok', false, 'reason', 'staging_changed');
  end;
end;
$$;

comment on function public.import_reopen_manual_resolutions(uuid, jsonb, integer[], jsonb)
is 'SPEC v3 §7.4: salva un batch di identita'' serie e riapre una sola volta il job in una '
   'transazione; gli episodi restano risolti esclusivamente dai loro id TVDB esatti.';

revoke all on function public.import_reopen_manual_resolutions(uuid, jsonb, integer[], jsonb)
  from public, anon, authenticated;
grant execute on function public.import_reopen_manual_resolutions(uuid, jsonb, integer[], jsonb)
  to service_role;
