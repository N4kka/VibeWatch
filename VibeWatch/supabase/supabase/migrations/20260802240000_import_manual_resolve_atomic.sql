-- SPEC v3 §7.4 — applicazione atomica della scelta manuale di una serie.
--
-- Mappa condivisa, righe di staging e riapertura del job sono un'unica decisione. Farle con
-- tre richieste PostgREST lascia uno stato parziale se il job non puo' tornare `running` (per
-- esempio per l'indice che ammette un solo job aperto per utente). Questa RPC e' il confine
-- transazionale: ogni esito negativo ripristina tutte le scritture del tentativo.

create or replace function public.import_reopen_manual_resolution(
  p_job_id uuid,
  p_tvdb_series_id bigint,
  p_tmdb_show_id integer,
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
  v_unique integer;
  v_resolution text;
  v_existing_show integer;
begin
  v_expected := cardinality(p_row_indexes);
  select count(distinct i)::integer into v_unique
    from unnest(coalesce(p_row_indexes, array[]::integer[])) as u(i);

  if p_job_id is null
     or p_tvdb_series_id is null or p_tvdb_series_id <= 0
     or p_tmdb_show_id is null or p_tmdb_show_id <= 0
     or p_totals is null or jsonb_typeof(p_totals) <> 'object'
     or coalesce(v_expected, 0) = 0
     or v_unique <> v_expected then
    return jsonb_build_object('ok', false, 'reason', 'invalid_plan');
  end if;

  begin
    -- L'UPDATE prende il lock sul job e, soprattutto, fa scattare qui l'indice parziale. Se
    -- fallisce, il blocco EXCEPTION e' una subtransazione: anche mappa e staging tornano come
    -- prima. Il lease concluso viene azzerato per rendere il job subito reclamabile dal driver.
    update public.import_jobs
       set phase = 'resolving',
           status = 'running',
           checkpoint = jsonb_build_object(
             'manual_episode_context', jsonb_build_object(
               'job_id', p_job_id,
               'tvdb_series_id', p_tvdb_series_id,
               'tmdb_show_id', p_tmdb_show_id
             )
           ),
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

    -- `ON CONFLICT DO NOTHING` chiude anche la corsa con un resolver concorrente: dopo
    -- l'eventuale attesa si rilegge la riga vincente sotto lock e non si sovrascrive mai un
    -- `found` che punta a un'altra serie.
    insert into public.tvdb_tmdb_map (
      tvdb_id, entity_type, tmdb_show_id, tmdb_movie_id,
      season_number, episode_number, resolution, method, resolved_at
    ) values (
      p_tvdb_series_id, 'series', p_tmdb_show_id, null,
      null, null, 'found', 'manual', now()
    )
    on conflict (tvdb_id, entity_type) do nothing;

    select resolution, tmdb_show_id
      into v_resolution, v_existing_show
      from public.tvdb_tmdb_map
     where tvdb_id = p_tvdb_series_id
       and entity_type = 'series'
     for update;

    if v_resolution = 'found' and v_existing_show <> p_tmdb_show_id then
      raise exception 'serie gia'' mappata' using errcode = 'VW002';
    elsif v_resolution <> 'found' then
      update public.tvdb_tmdb_map
         set tmdb_show_id = p_tmdb_show_id,
             tmdb_movie_id = null,
             season_number = null,
             episode_number = null,
             resolution = 'found',
             method = 'manual',
             resolved_at = now()
       where tvdb_id = p_tvdb_series_id
         and entity_type = 'series';
    end if;

    -- Si aggiornano soltanto le classi che l'endpoint puo' pianificare. Se una riga e' stata
    -- modificata tra lettura e RPC, il conteggio non coincide e tutto il tentativo fa rollback.
    update public.import_staging
       set resolved = null,
           status = 'pending',
           error = null
     where job_id = p_job_id
       and row_index = any(p_row_indexes)
       and (
         (status = 'unresolved' and error like 'catalogo:%')
         or (
           status = 'skipped'
           and error = 'voti: non_risolto'
           and not exists (
             select 1
               from public.tvdb_tmdb_map episode_map
              where episode_map.entity_type = 'episode'
                and episode_map.tvdb_id::text = import_staging.raw->>'tvdb_episode_id'
                and episode_map.resolution = 'found'
                and episode_map.tmdb_show_id is distinct from p_tmdb_show_id
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
        'tmdb_show_id', v_existing_show
      );
    when sqlstate 'VW003' then
      return jsonb_build_object('ok', false, 'reason', 'staging_changed');
  end;
end;
$$;

comment on function public.import_reopen_manual_resolution(uuid, bigint, integer, integer[], jsonb)
is 'SPEC v3 §7.4: salva la serie scelta, riapre le sole righe dichiarate e riporta il job a '
   'resolving in una transazione; nessuna identita'' episodio deriva dai numeri dell''export.';

revoke all on function public.import_reopen_manual_resolution(uuid, bigint, integer, integer[], jsonb)
  from public, anon, authenticated;
grant execute on function public.import_reopen_manual_resolution(uuid, bigint, integer, integer[], jsonb)
  to service_role;
