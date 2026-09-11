-- SPEC v3 §1.5/§6 — scrittura race-safe della mappa condivisa TVDB→TMDB.
--
-- Il cache-first dell'Edge Function evita normalmente di ritentare un `found`, ma fra SELECT e
-- UPSERT un altro resolver puo' completare la stessa chiave. La clausola WHERE dell'UPSERT viene
-- valutata sulla riga bloccata piu' recente: anche in quella corsa, un `found` resta immutabile.

create or replace function public.catalog_store_tvdb_map(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if p_rows is null
     or jsonb_typeof(p_rows) <> 'array'
     or jsonb_array_length(p_rows) < 1
     or jsonb_array_length(p_rows) > 50 then
    raise exception 'catalog_store_tvdb_map: batch non valido'
      using errcode = '22023';
  end if;

  insert into public.tvdb_tmdb_map as existing (
    tvdb_id, entity_type, tmdb_show_id, tmdb_movie_id,
    season_number, episode_number, resolution, method, resolved_at
  )
  select
    row.tvdb_id, row.entity_type, row.tmdb_show_id, row.tmdb_movie_id,
    row.season_number, row.episode_number, row.resolution, row.method,
    coalesce(row.resolved_at, now())
  from jsonb_to_recordset(p_rows) as row(
    tvdb_id bigint,
    entity_type text,
    tmdb_show_id integer,
    tmdb_movie_id integer,
    season_number integer,
    episode_number integer,
    resolution text,
    method text,
    resolved_at timestamptz
  )
  on conflict (tvdb_id, entity_type) do update
     set tmdb_show_id = excluded.tmdb_show_id,
         tmdb_movie_id = excluded.tmdb_movie_id,
         season_number = excluded.season_number,
         episode_number = excluded.episode_number,
         resolution = excluded.resolution,
         method = excluded.method,
         resolved_at = excluded.resolved_at
   where existing.resolution <> 'found';

  -- Non si ritorna il tentativo, ma la verita' dopo il lock/upsert. Se un `found` concorrente ha
  -- vinto, catalog-resolve e i suoi caller vedono quello e non una risposta ormai obsoleta.
  select coalesce(jsonb_agg(to_jsonb(stored) order by stored.tvdb_id, stored.entity_type), '[]')
    into v_result
    from public.tvdb_tmdb_map stored
   where exists (
     select 1
       from jsonb_to_recordset(p_rows) as requested(tvdb_id bigint, entity_type text)
      where requested.tvdb_id = stored.tvdb_id
        and requested.entity_type = stored.entity_type
   );

  return v_result;
end;
$$;

comment on function public.catalog_store_tvdb_map(jsonb) is
  'SPEC v3 §1.5/§6: upsert race-safe della cache TVDB→TMDB; una riga found non viene mai '
  'sovrascritta e la risposta contiene le righe effettivamente persistite.';

revoke all on function public.catalog_store_tvdb_map(jsonb)
  from public, anon, authenticated;
grant execute on function public.catalog_store_tvdb_map(jsonb)
  to service_role;
