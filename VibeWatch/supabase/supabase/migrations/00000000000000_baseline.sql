


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


-- Aggiunto a mano alla baseline prodotta da `supabase db dump --schema public`:
-- il dump di un singolo schema non emette le extension, ma lo schema le usa
-- (profiles.username e' `extensions.citext`, la ricerca usa pg_trgm, i cron
-- usano pg_net). Senza queste righe la baseline non e' applicabile a un
-- database vuoto — ed e' proprio quello che deve saper fare.
CREATE SCHEMA IF NOT EXISTS "extensions";
CREATE EXTENSION IF NOT EXISTS "citext"    WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"   WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pgcrypto"  WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pg_net"    WITH SCHEMA "extensions";

-- Gestite dalla piattaforma Supabase, non ricreabili da una migration:
-- pg_cron (pg_catalog, vuole shared_preload_libraries), supabase_vault,
-- pg_stat_statements, plpgsql, hypopg/index_advisor (sola diagnostica).


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."activities_refresh_completed"("p_user" "uuid", "p_show" integer, "p_completed_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_key    text := 'completed:tv:' || p_show;
  v_title  text;
  v_poster text;
begin
  if p_completed_at is null or not exists (
       select 1 from public.watch_events e
        where e.user_id = p_user and e.media_type = 'tv' and e.tmdb_show_id = p_show
          and e.deleted_at is null
          and e.source not like 'import\_%' escape '\'
     ) then
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = p_user and group_key = v_key and deleted_at is null;
    return;
  end if;

  select name, poster_path into v_title, v_poster
    from public.tmdb_shows where tmdb_show_id = p_show;

  insert into public.activities as a
    (user_id, activity_type, group_key, media_type, tmdb_id, title, poster_path, occurred_at)
  values
    (p_user, 'show_completed', v_key, 'tv', p_show, v_title, v_poster, p_completed_at)
  on conflict (user_id, group_key) do update set
    title = coalesce(excluded.title, a.title),
    poster_path = coalesce(excluded.poster_path, a.poster_path),
    occurred_at = excluded.occurred_at,
    deleted_at = null,
    updated_at = now();
end $$;


ALTER FUNCTION "public"."activities_refresh_completed"("p_user" "uuid", "p_show" integer, "p_completed_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activities_refresh_rated"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_key       text := 'rated:' || p_media_type || ':' || p_tmdb;
  v_rating    smallint;
  v_rating_at timestamptz;
  v_review    uuid;
  v_review_at timestamptz;
  v_title     text;
  v_poster    text;
begin
  if p_media_type not in ('movie','tv') then
    return;
  end if;

  select rating, updated_at into v_rating, v_rating_at
    from public.user_ratings
   where user_id = p_user and media_type = p_media_type and tmdb_id = p_tmdb
     and season_number is null and episode_number is null
     and deleted_at is null;

  select id, updated_at into v_review, v_review_at
    from public.user_reviews
   where user_id = p_user and media_type = p_media_type and tmdb_id = p_tmdb
     and deleted_at is null;

  if v_rating is null and v_review is null then
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = p_user and group_key = v_key and deleted_at is null;
    return;
  end if;

  if p_media_type = 'tv' then
    select name, poster_path into v_title, v_poster
      from public.tmdb_shows where tmdb_show_id = p_tmdb;
  end if;

  insert into public.activities as a
    (user_id, activity_type, group_key, media_type, tmdb_id, rating, review_id,
     title, poster_path, occurred_at)
  values
    (p_user, 'rated', v_key, p_media_type, p_tmdb, v_rating, v_review, v_title, v_poster,
     greatest(coalesce(v_rating_at, '-infinity'::timestamptz),
              coalesce(v_review_at, '-infinity'::timestamptz)))
  on conflict (user_id, group_key) do update set
    rating = excluded.rating,
    review_id = excluded.review_id,
    title = coalesce(excluded.title, a.title),
    poster_path = coalesce(excluded.poster_path, a.poster_path),
    occurred_at = excluded.occurred_at,
    deleted_at = null,
    updated_at = now();
end $$;


ALTER FUNCTION "public"."activities_refresh_rated"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activities_refresh_watch"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer, "p_day" "date", "p_rewatch" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_key      text;
  v_count    integer;
  v_last     timestamptz;
  v_episodes integer;
  v_title    text;
  v_poster   text;
begin
  if p_media_type = 'movie' then
    v_key := 'watch:movie:' || p_tmdb || ':' || coalesce(p_rewatch, 0);
    select count(*), max(watched_at) into v_count, v_last
      from public.watch_events
     where user_id = p_user and media_type = 'movie' and tmdb_movie_id = p_tmdb
       and coalesce(rewatch_index, 0) = coalesce(p_rewatch, 0)
       and deleted_at is null
       and source not like 'import\_%' escape '\' and source <> 'bulk_show'
       and watched_at_precision <> 'inferred';
    v_episodes := null;
  elsif p_media_type = 'tv' then
    v_key := 'watch:tv:' || p_tmdb || ':' || p_day;
    select count(*), max(watched_at) into v_count, v_last
      from public.watch_events
     where user_id = p_user and media_type = 'tv' and tmdb_show_id = p_tmdb
       and (watched_at at time zone 'utc')::date = p_day
       and deleted_at is null
       and source not like 'import\_%' escape '\' and source <> 'bulk_show'
       and watched_at_precision <> 'inferred';
    v_episodes := v_count;
    select name, poster_path into v_title, v_poster
      from public.tmdb_shows where tmdb_show_id = p_tmdb;
  else
    return;
  end if;

  if coalesce(v_count, 0) = 0 then
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = p_user and group_key = v_key and deleted_at is null;
    return;
  end if;

  insert into public.activities as a
    (user_id, activity_type, group_key, media_type, tmdb_id, episode_count,
     title, poster_path, occurred_at)
  values
    (p_user, 'watched', v_key, p_media_type, p_tmdb, v_episodes, v_title, v_poster, v_last)
  on conflict (user_id, group_key) do update set
    episode_count = excluded.episode_count,
    title = coalesce(excluded.title, a.title),
    poster_path = coalesce(excluded.poster_path, a.poster_path),
    occurred_at = excluded.occurred_at,
    deleted_at = null,
    updated_at = now();
end $$;


ALTER FUNCTION "public"."activities_refresh_watch"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer, "p_day" "date", "p_rewatch" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activity_interaction_gate"("p_activity_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid   uuid := (select auth.uid());
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  select a.user_id into v_owner
    from public.activities a
    join public.profiles p on p.id = a.user_id
   where a.id = p_activity_id
     and a.deleted_at is null
     and a.hidden_at is null
     and (a.user_id = v_uid
          or (p.deleted_at is null
              and p.username is not null
              and p.is_profile_public
              and p.activity_feed_enabled
              and p.feed_activated_at is not null));

  if v_owner is null then
    raise exception 'activity_not_available' using errcode = 'P0002';
  end if;

  if v_owner <> v_uid and exists (
       select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = v_uid and b.blocked_user_id = v_owner)
            or (b.user_id = v_owner and b.blocked_user_id = v_uid))
     ) then
    -- Stessa risposta dell'inesistente: il blocco non si annuncia.
    raise exception 'activity_not_available' using errcode = 'P0002';
  end if;

  return v_owner;
end $$;


ALTER FUNCTION "public"."activity_interaction_gate"("p_activity_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_activity_comment"("p_activity_id" "uuid", "p_content" "text", "p_comment_id" "uuid" DEFAULT NULL::"uuid", "p_parent_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid := coalesce(p_comment_id, gen_random_uuid());
begin
  perform public.activity_interaction_gate(p_activity_id);

  if char_length(btrim(coalesce(p_content, ''))) not between 1 and 1000 then
    raise exception 'invalid_content' using errcode = '23514';
  end if;

  if p_parent_id is not null and not exists (
       select 1 from public.activity_comments c
        where c.id = p_parent_id and c.activity_id = p_activity_id and c.deleted_at is null
     ) then
    raise exception 'parent_not_available' using errcode = 'P0002';
  end if;

  insert into public.activity_comments as t
    (id, activity_id, user_id, parent_id, content, synced_at)
  values
    (v_id, p_activity_id, v_uid, p_parent_id, btrim(p_content), now())
  on conflict (id) do update set
    content = excluded.content,
    updated_at = now(),
    synced_at = now()
  where t.user_id = v_uid;

  return v_id;
end $$;


ALTER FUNCTION "public"."add_activity_comment"("p_activity_id" "uuid", "p_content" "text", "p_comment_id" "uuid", "p_parent_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_proxy_bump_hit"("p_provider" "text", "p_cache_key" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update public.api_proxy_cache
     set hit_count = hit_count + 1
   where provider = p_provider and cache_key = p_cache_key;
$$;


ALTER FUNCTION "public"."api_proxy_bump_hit"("p_provider" "text", "p_cache_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_proxy_prune"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  delete from public.api_proxy_cache where expires_at < now();
  delete from public.api_proxy_budget where window_start < now() - interval '35 days';
$$;


ALTER FUNCTION "public"."api_proxy_prune"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_proxy_refund"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update public.api_proxy_budget
     set call_count = greatest(call_count - 1, 0),
         updated_at = now()
   where provider = p_provider
     and scope = p_scope
     and window_start = p_window_start;
$$;


ALTER FUNCTION "public"."api_proxy_refund"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_proxy_try_spend"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone, "p_limit" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  insert into public.api_proxy_budget (provider, scope, window_start, call_count, updated_at)
  values (p_provider, p_scope, p_window_start, 1, now())
  on conflict (provider, scope, window_start) do update
    set call_count = public.api_proxy_budget.call_count + 1,
        updated_at = now()
  returning call_count into v_count;

  -- Over budget: give the unit back so a rejected call does not keep inflating the counter.
  if v_count > p_limit then
    update public.api_proxy_budget
       set call_count = call_count - 1
     where provider = p_provider and scope = p_scope and window_start = p_window_start;
    return false;
  end if;

  return true;
end;
$$;


ALTER FUNCTION "public"."api_proxy_try_spend"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_mutations"("batch" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  declare
    item jsonb;
    op text;
    tbl text;
    rec jsonb;
    rec_id text;
    v_uid uuid := (select auth.uid());
    v_write boolean;
    v_handled boolean;
    v_reason text;
    v_error text;
  begin
    if v_uid is null then
      raise exception 'unauthenticated';
    end if;

    for item in select * from jsonb_array_elements(batch)
    loop
      op := upper(coalesce(item->>'op',''));
      tbl := item->>'table';
      rec := item->'record';
      rec_id := item->>'id';
      -- "UPSERT" is what six of the client's call sites send; it used to match nothing.
      v_write := op in ('INSERT','UPDATE','UPSERT');
      v_handled := true;
      v_reason := null;
      v_error := null;

      begin

      if v_write and (case when tbl = 'user_follows' then rec->>'follower_id'
                           else rec->>'user_id' end) is distinct from v_uid::text then
        -- La colonna d'identita' non si chiama uguale ovunque: per user_follows e' follower_id
        -- (la tabella non ha user_id). Per tutte le altre tabelle il confronto e' quello di prima.
        v_handled := false;
        v_reason := 'user_id_mismatch';

      elsif tbl = 'lists' then
        if v_write then
          -- Una sola default ATTIVA per (user_id, type): l'INSERT che il client accoda per una
          -- lista core e' un "ensure", non una creazione. Se una default di quel tipo esiste
          -- gia' — con un ALTRO id, quindi invisibile all'upsert su (id) — l'intento e' gia'
          -- soddisfatto: rifiutare riempiva sync_rejected_mutations di constraint_23505 per un
          -- esito corretto. L'id canonico il client lo adotta dal pull. Ogni ALTRA violazione
          -- di unicita' resta un errore vero e risale al catch per-item.
          begin
            insert into public.lists as t
              (id, user_id, name, description, type, is_public, source_list_id, source_list_type,
               created_at, updated_at, deleted_at, synced_at)
            values
              ((rec->>'id')::uuid, (rec->>'user_id')::uuid, rec->>'name', rec->>'description', rec->>'type',
               (coalesce((rec->>'is_public')::boolean, false) and (rec->>'type') = 'custom'),
               nullif(rec->>'source_list_id', '')::uuid,
               nullif(rec->>'source_list_type', ''),
               (rec->>'created_at')::timestamptz, (rec->>'updated_at')::timestamptz,
               (rec->>'deleted_at')::timestamptz, now())
            on conflict (id) do update set
              name = excluded.name,
              description = excluded.description,
              type = excluded.type,
              is_public = (coalesce((rec->>'is_public')::boolean, t.is_public) and excluded.type = 'custom'),
              source_list_id = excluded.source_list_id,
              source_list_type = excluded.source_list_type,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          exception when unique_violation then
            if sqlerrm not like '%idx_lists_one_active_default_per_user_type%' then
              raise;
            end if;
          end;
        elsif op = 'DELETE' then
          update public.lists set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'list_items' then
        if v_write then
          -- The destination list must belong to the caller. Owning the *row* is not enough:
          -- without this, a row with a legitimate user_id lands inside another user's list.
          if not exists (
            select 1 from public.lists l
            where l.id = nullif(rec->>'list_id','')::uuid
              and l.user_id = v_uid
          ) then
            v_handled := false;
            v_reason := 'list_not_owned';
          else
            insert into public.list_items as t
              (id, list_id, user_id, media_id, media_type, title, poster_path, runtime,
               vote_average, vote_count, origin_country, release_date, genres, overview,
               added_at, created_at, deleted_at, synced_at)
            values
              ((rec->>'id')::uuid, (rec->>'list_id')::uuid, (rec->>'user_id')::uuid, (rec->>'media_id')::int, rec->>'media_type',
               rec->>'title', rec->>'poster_path', nullif(rec->>'runtime','')::int,
               nullif(rec->>'vote_average','')::numeric, nullif(rec->>'vote_count','')::int,
               case when jsonb_typeof(rec->'origin_country') = 'array' then array(select jsonb_array_elements_text(rec->'origin_country')) else null end,
               rec->>'release_date',
               case when jsonb_typeof(rec->'genres') = 'array' then array(select (jsonb_array_elements(rec->'genres'))::int) else null end,
               rec->>'overview',
               (rec->>'added_at')::timestamptz,
               (rec->>'created_at')::timestamptz,
               (rec->>'deleted_at')::timestamptz,
               now())
            on conflict (id) do update set
              list_id = excluded.list_id,
              user_id = excluded.user_id,
              media_id = excluded.media_id,
              media_type = excluded.media_type,
              title = excluded.title,
              poster_path = excluded.poster_path,
              runtime = excluded.runtime,
              vote_average = excluded.vote_average,
              vote_count = excluded.vote_count,
              origin_country = excluded.origin_country,
              release_date = excluded.release_date,
              genres = excluded.genres,
              overview = excluded.overview,
              added_at = excluded.added_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          delete from public.list_items where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'list_follows' then
        if v_write then
          insert into public.list_follows as t
            (id, user_id, list_id, created_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, (rec->>'list_id')::uuid,
             (rec->>'created_at')::timestamptz, (rec->>'deleted_at')::timestamptz, now())
          on conflict (id) do update set
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          update public.list_follows set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'user_blocks' then
        if v_write then
          insert into public.user_blocks as t
            (id, user_id, blocked_user_id, created_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, (rec->>'blocked_user_id')::uuid,
             (rec->>'created_at')::timestamptz, (rec->>'deleted_at')::timestamptz, now())
          on conflict (id) do update set
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          update public.user_blocks set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'list_reports' then
        if v_write then
          insert into public.list_reports as t
            (id, user_id, list_id, reason, created_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, (rec->>'list_id')::uuid, rec->>'reason',
             (rec->>'created_at')::timestamptz, now())
          on conflict (user_id, list_id) do nothing;
        end if;

      elsif tbl = 'user_search_history' then
        if v_write then
          if coalesce(rec->>'query','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.user_search_history as t
              (id, user_id, device_id, query, media_type, result_count, clicked_media_id,
               clicked_media_title, searched_at, relevance_score, synced_at)
            values
              ((rec->>'id')::uuid, v_uid, coalesce(nullif(rec->>'device_id',''),'unknown'),
               rec->>'query', rec->>'media_type', nullif(rec->>'result_count','')::int,
               nullif(rec->>'clicked_media_id','')::int, rec->>'clicked_media_title',
               coalesce(nullif(rec->>'searched_at','')::timestamptz, now()),
               nullif(rec->>'relevance_score','')::real, now())
            on conflict (id) do update set
              query = excluded.query,
              media_type = excluded.media_type,
              result_count = excluded.result_count,
              clicked_media_id = excluded.clicked_media_id,
              clicked_media_title = excluded.clicked_media_title,
              searched_at = excluded.searched_at,
              relevance_score = excluded.relevance_score,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          delete from public.user_search_history where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'user_clip_signals' then
        if v_write then
          if coalesce(rec->>'clip_id','') = '' or coalesce(rec->>'signal_type','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.user_clip_signals as t
              (id, user_id, device_id, clip_id, signal_type, signal_value, source, position,
               session_id, occurred_at, synced_at)
            values
              ((rec->>'id')::uuid, v_uid, coalesce(nullif(rec->>'device_id',''),'unknown'),
               rec->>'clip_id', rec->>'signal_type',
               nullif(rec->>'signal_value','')::double precision, rec->>'source',
               nullif(rec->>'position','')::int, rec->>'session_id',
               coalesce(nullif(rec->>'occurred_at','')::timestamptz, now()), now())
            on conflict (id) do update set
              signal_type = excluded.signal_type,
              signal_value = excluded.signal_value,
              source = excluded.source,
              position = excluded.position,
              session_id = excluded.session_id,
              occurred_at = excluded.occurred_at,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          delete from public.user_clip_signals where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'user_discovery_interactions' then
        if v_write then
          if coalesce(rec->>'media_id','') = '' or coalesce(rec->>'media_type','') = ''
             or coalesce(rec->>'carousel_type','') = '' or coalesce(rec->>'interaction_type','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.user_discovery_interactions as t
              (id, user_id, device_id, media_id, media_type, carousel_type, interaction_type,
               interacted_at, session_duration, filter_active, filter_config, synced_at)
            values
              ((rec->>'id')::uuid, v_uid, coalesce(nullif(rec->>'device_id',''),'unknown'),
               (rec->>'media_id')::int, rec->>'media_type', rec->>'carousel_type',
               rec->>'interaction_type',
               coalesce(nullif(rec->>'interacted_at','')::timestamptz, now()),
               nullif(rec->>'session_duration','')::int,
               nullif(rec->>'filter_active','')::boolean,
               case when jsonb_typeof(rec->'filter_config') = 'object' then rec->'filter_config' else null end,
               now())
            on conflict (id) do nothing;
          end if;
        elsif op = 'DELETE' then
          delete from public.user_discovery_interactions where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'ai_conversation_history' then
        if v_write then
          if coalesce(rec->>'session_id','') = '' or coalesce(rec->>'message_type','') = ''
             or coalesce(rec->>'content','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.ai_conversation_history as t
              (id, user_id, device_id, session_id, message_type, content, query_type,
               mentioned_media_ids, mentioned_genres, tokens_used, created_at)
            values
              ((rec->>'id')::uuid, v_uid, coalesce(nullif(rec->>'device_id',''),'unknown'),
               rec->>'session_id', rec->>'message_type', rec->>'content', rec->>'query_type',
               case when jsonb_typeof(rec->'mentioned_media_ids') = 'array' then rec->'mentioned_media_ids' else null end,
               case when jsonb_typeof(rec->'mentioned_genres') = 'array' then rec->'mentioned_genres' else null end,
               nullif(rec->>'tokens_used','')::int,
               coalesce(nullif(rec->>'created_at','')::timestamptz, now()))
            on conflict (id) do nothing;
          end if;
        elsif op = 'DELETE' then
          delete from public.ai_conversation_history where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'global_discovery_filters' then
        if v_write then
          insert into public.global_discovery_filters as t
            (user_id, device_id, media_type, runtime_min, runtime_max, rating_min, rating_max,
             release_year_start, release_year_end, countries, sort_by, hide_watched, hide_disliked,
             updated_at, created_at)
          values
            (v_uid, coalesce(nullif(rec->>'device_id',''),'unknown'), rec->>'media_type',
             nullif(rec->>'runtime_min','')::int, nullif(rec->>'runtime_max','')::int,
             nullif(rec->>'rating_min','')::real, nullif(rec->>'rating_max','')::real,
             nullif(rec->>'release_year_start','')::int, nullif(rec->>'release_year_end','')::int,
             case when jsonb_typeof(rec->'countries') = 'array' then rec->'countries' else null end,
             rec->>'sort_by',
             nullif(rec->>'hide_watched','')::boolean, nullif(rec->>'hide_disliked','')::boolean,
             coalesce(nullif(rec->>'updated_at','')::timestamptz, now()), now())
          on conflict (user_id) do update set
            device_id = excluded.device_id,
            media_type = excluded.media_type,
            runtime_min = excluded.runtime_min,
            runtime_max = excluded.runtime_max,
            rating_min = excluded.rating_min,
            rating_max = excluded.rating_max,
            release_year_start = excluded.release_year_start,
            release_year_end = excluded.release_year_end,
            countries = excluded.countries,
            sort_by = excluded.sort_by,
            hide_watched = excluded.hide_watched,
            hide_disliked = excluded.hide_disliked,
            updated_at = excluded.updated_at
          where t.user_id = v_uid;
        elsif op = 'DELETE' then
          delete from public.global_discovery_filters where user_id = v_uid;
        end if;

      elsif tbl = 'user_badges' then
        if v_write then
          if coalesce(rec->>'badge_id','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            -- The client's record id is "{userId}_{badgeId}", which is not a uuid. The natural
            -- key is unique, so the id is generated here and the client's is ignored.
            insert into public.user_badges as t
              (id, user_id, badge_id, progress, target, unlocked_at, updated_at)
            values
              (gen_random_uuid(), v_uid, rec->>'badge_id',
               coalesce(nullif(rec->>'progress','')::int, 0),
               coalesce(nullif(rec->>'target','')::int, 0),
               nullif(rec->>'unlocked_at','')::timestamptz,
               coalesce(nullif(rec->>'updated_at','')::timestamptz, now()))
            on conflict (user_id, badge_id) do update set
              progress = excluded.progress,
              target = excluded.target,
              unlocked_at = excluded.unlocked_at,
              updated_at = excluded.updated_at
            where t.user_id = v_uid;
          end if;
        end if;

      elsif tbl = 'user_daily_challenges' then
        if v_write then
          if coalesce(rec->>'challenge_date','') = '' or coalesce(rec->>'challenge_type','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            -- Keyed on (user, date, type) rather than the client id: the same challenge is queued
            -- once as INSERT and again as UPSERT on every progress tick.
            insert into public.user_daily_challenges as t
              (id, user_id, challenge_date, challenge_type, challenge_description, target,
               progress, xp_reward, completed_at, created_at)
            values
              (gen_random_uuid(), v_uid, (rec->>'challenge_date')::date, rec->>'challenge_type',
               coalesce(rec->>'challenge_description',''),
               coalesce(nullif(rec->>'target','')::int, 0),
               coalesce(nullif(rec->>'progress','')::int, 0),
               coalesce(nullif(rec->>'xp_reward','')::int, 0),
               nullif(rec->>'completed_at','')::timestamptz,
               coalesce(nullif(rec->>'created_at','')::timestamptz, now()))
            on conflict (user_id, challenge_date, challenge_type) do update set
              challenge_description = excluded.challenge_description,
              target = excluded.target,
              progress = excluded.progress,
              xp_reward = excluded.xp_reward,
              completed_at = excluded.completed_at
            where t.user_id = v_uid;
          end if;
        end if;

      elsif tbl = 'movie_reactions' then
        -- STAB-011. Ricopiato QUI dal `prosrc` reale, non dedotto: in produzione questo branch
        -- era stato aggiunto per splice (20260723135625), e riscrivere la funzione intera senza
        -- ricopiarlo lo avrebbe cancellato — ogni reaction sarebbe tornata a `table_not_handled`.
        if v_write then
          if coalesce(rec->>'media_id','') = '' or coalesce(rec->>'media_type','') = ''
             or coalesce(rec->>'reaction_type','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.movie_reactions as t
              (id, user_id, media_id, media_type, reaction_type, created_at, updated_at, deleted_at, synced_at)
            values
              (coalesce(nullif(rec->>'id','')::uuid, gen_random_uuid()), v_uid,
               (rec->>'media_id')::int, rec->>'media_type', rec->>'reaction_type',
               coalesce(nullif(rec->>'created_at','')::timestamptz, now()),
               coalesce(nullif(rec->>'updated_at','')::timestamptz, now()),
               nullif(rec->>'deleted_at','')::timestamptz, now())
            on conflict (user_id, media_id, media_type) do update set
              reaction_type = excluded.reaction_type,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          delete from public.movie_reactions where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'unified_user_preferences' then
        -- STAB-010, stessa storia: splice in produzione (20260723205456), ricopiato qui.
        if v_write then
          if coalesce(rec->>'preference_category','') = '' or coalesce(rec->>'preference_id','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.unified_user_preferences as t
              (id, user_id, device_id, preference_category, preference_id, preference_name,
               score, score_from_clips, score_from_discovery, score_from_search, score_from_ai,
               score_from_lists, interaction_count, last_interaction_at, created_at, updated_at)
            values
              (coalesce(nullif(rec->>'id','')::uuid, gen_random_uuid()), v_uid,
               coalesce(nullif(rec->>'device_id',''),'unknown'), rec->>'preference_category', rec->>'preference_id',
               rec->>'preference_name',
               coalesce(nullif(rec->>'score','')::real, 0),
               coalesce(nullif(rec->>'score_from_clips','')::real, 0),
               coalesce(nullif(rec->>'score_from_discovery','')::real, 0),
               coalesce(nullif(rec->>'score_from_search','')::real, 0),
               coalesce(nullif(rec->>'score_from_ai','')::real, 0),
               coalesce(nullif(rec->>'score_from_lists','')::real, 0),
               coalesce(nullif(rec->>'interaction_count','')::int, 0),
               nullif(rec->>'last_interaction_at','')::timestamptz,
               now(),
               coalesce(nullif(rec->>'updated_at','')::timestamptz, now()))
            on conflict (user_id, preference_category, preference_id) do update set
              preference_name = excluded.preference_name,
              score = excluded.score,
              score_from_clips = excluded.score_from_clips,
              score_from_discovery = excluded.score_from_discovery,
              score_from_search = excluded.score_from_search,
              score_from_ai = excluded.score_from_ai,
              score_from_lists = excluded.score_from_lists,
              interaction_count = excluded.interaction_count,
              last_interaction_at = excluded.last_interaction_at,
              updated_at = excluded.updated_at
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          delete from public.unified_user_preferences where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'user_reviews' then
        -- Social feed M1: review breve, id client autoritativo. La bonifica della chiave
        -- naturale sta nel commento di testa della migration 20260812140000.
        if v_write then
          if coalesce(btrim(rec->>'content'),'') = '' or coalesce(rec->>'media_type','') = ''
             or coalesce(rec->>'tmdb_id','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            update public.user_reviews set deleted_at = now(), synced_at = now()
            where user_id = v_uid
              and media_type = rec->>'media_type'
              and tmdb_id = (rec->>'tmdb_id')::integer
              and deleted_at is null
              and id <> (rec->>'id')::uuid;
            insert into public.user_reviews as t
              (id, user_id, media_type, tmdb_id, content, contains_spoilers,
               created_at, updated_at, deleted_at, synced_at)
            values
              ((rec->>'id')::uuid, v_uid, rec->>'media_type', (rec->>'tmdb_id')::integer,
               rec->>'content',
               coalesce((rec->>'contains_spoilers')::boolean, false),
               coalesce(nullif(rec->>'created_at','')::timestamptz, now()),
               coalesce(nullif(rec->>'updated_at','')::timestamptz, now()),
               nullif(rec->>'deleted_at','')::timestamptz, now())
            on conflict (id) do update set
              content = excluded.content,
              contains_spoilers = excluded.contains_spoilers,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          update public.user_reviews set deleted_at = now(), synced_at = now()
          where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl in ('user_gamification','xp_transactions') then
        -- Server-authoritative through award_xp. Giving these a branch would reopen XP
        -- self-award through the definer.
        v_handled := false;
        v_reason := 'server_authoritative';

      elsif tbl = 'watch_events' then
        -- SPEC v3 §4: strategia `union`. Sono eventi append-only e non se ne perde mai uno: un
        -- re-push dello stesso evento non riscrive nulla, due eventi diversi convivono. Per
        -- questo l'ON CONFLICT tocca solo il soft-delete e synced_at, mai il contenuto.
        if v_write then
          -- Criterio 2 di §13: reimportare lo stesso ZIP non duplica. La dedup si fa PRIMA
          -- dell'insert e non lasciando esplodere l'indice unico: un import ripetuto e' un caso
          -- normale, non un errore, e riempire sync_rejected_mutations di violazioni attese
          -- renderebbe illeggibile la tabella che serve a vedere i problemi veri.
          insert into public.watch_events as t
            (id, user_id, media_type, tmdb_movie_id, tmdb_show_id, season_number, episode_number,
             watched_at, logged_at, watched_at_precision, runtime_seconds, is_special,
             rewatch_index, source, external_ref, dedup_key, device_id, deleted_at, synced_at)
          select
            coalesce((rec->>'id')::uuid, gen_random_uuid()), v_uid, rec->>'media_type',
            (rec->>'tmdb_movie_id')::integer, (rec->>'tmdb_show_id')::integer,
            (rec->>'season_number')::integer, (rec->>'episode_number')::integer,
            (rec->>'watched_at')::timestamptz,
            coalesce((rec->>'logged_at')::timestamptz, now()),
            coalesce(rec->>'watched_at_precision', 'exact'),
            (rec->>'runtime_seconds')::integer,
            coalesce((rec->>'is_special')::boolean, false),
            coalesce((rec->>'rewatch_index')::integer, 0),
            coalesce(rec->>'source', 'manual'),
            rec->'external_ref',
            rec->>'dedup_key', rec->>'device_id',
            (rec->>'deleted_at')::timestamptz, now()
          where (rec->>'dedup_key') is null
             or not exists (
                  select 1 from public.watch_events d
                   where d.user_id = v_uid
                     and d.dedup_key = rec->>'dedup_key'
                     and d.deleted_at is null
                )
          on conflict (id) do update set
            deleted_at = excluded.deleted_at,
            synced_at  = now();
        elsif op = 'DELETE' then
          -- Nessuna DELETE fisica: si cancella con deleted_at, e il trigger ricalcola lo stato.
          update public.watch_events
             set deleted_at = coalesce((rec->>'deleted_at')::timestamptz, now()),
                 synced_at  = now()
           where id = rec_id::uuid and user_id = v_uid;
        end if;

      elsif tbl = 'tv_show_state' then
        -- §4: strategia `serverWins`. La riga e' derivata e l'autorevole e' il server (§1.1):
        -- dal client si accetta SOLO `user_status`, che e' una sua scelta. I contatori arrivano
        -- dal ricalcolo, coerentemente con i grant per colonna sulla tabella.
        if v_write then
          insert into public.tv_show_state as t (user_id, tmdb_show_id, user_status, updated_at)
          values (v_uid, (rec->>'tmdb_show_id')::integer,
                  coalesce(rec->>'user_status', 'active'), now())
          on conflict (user_id, tmdb_show_id) do update set
            user_status = excluded.user_status,
            updated_at  = now();
          -- Una riga creata dal client nasce a zero: il ricalcolo la allinea agli eventi che
          -- l'utente ha gia'. Senza, una serie messa "da vedere piu' avanti" resterebbe a 0/0.
          perform public.recompute_tv_show_state(v_uid, (rec->>'tmdb_show_id')::integer);
        elsif op = 'DELETE' then
          v_handled := false;
          v_reason := 'server_authoritative';
        end if;

      elsif tbl = 'user_follows' then
        -- §4: strategia `union`, come user_blocks: il soft delete e' l'unfollow, il re-follow
        -- riusa la riga. L'ON CONFLICT tocca solo deleted_at e synced_at. Il trigger
        -- user_follows_blocked decide sui blocchi, in entrambi i versi.
        if v_write then
          insert into public.user_follows as t
            (follower_id, followee_id, created_at, deleted_at, synced_at)
          values
            ((rec->>'follower_id')::uuid, (rec->>'followee_id')::uuid,
             coalesce((rec->>'created_at')::timestamptz, now()),
             (rec->>'deleted_at')::timestamptz, now())
          on conflict (follower_id, followee_id) do update set
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.follower_id = v_uid;
        elsif op = 'DELETE' then
          -- `rec_id` qui e' il followee: la PK e' la coppia e il follower e' il chiamante.
          update public.user_follows set deleted_at = now(), synced_at = now()
          where follower_id = v_uid and followee_id = rec_id::uuid;
        end if;

      elsif tbl = 'user_favorites' then
        -- SPEC v3 §3.6/§4: lastWriteWins sulla PK (utente, media, slot). Svuotare uno slot e'
        -- una lapide (deleted_at), mai una DELETE fisica: il pull la porta anche agli altri
        -- dispositivi. Riempire di nuovo lo slot riusa la riga: la PK e' lo slot stesso.
        if v_write then
          if coalesce(rec->>'media_type','') = '' or coalesce(rec->>'slot','') = ''
             or coalesce(rec->>'tmdb_id','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            insert into public.user_favorites as t
              (user_id, media_type, slot, tmdb_id, updated_at, deleted_at, synced_at)
            values
              (v_uid, rec->>'media_type', (rec->>'slot')::smallint, (rec->>'tmdb_id')::integer,
               coalesce(nullif(rec->>'updated_at','')::timestamptz, now()),
               nullif(rec->>'deleted_at','')::timestamptz, now())
            on conflict (user_id, media_type, slot) do update set
              tmdb_id = excluded.tmdb_id,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at,
              synced_at = now()
            where t.user_id = v_uid;
          end if;
        elsif op = 'DELETE' then
          -- La chiave e' (media_type, slot), due campi: non entra in `id`. Una DELETE esplicita
          -- si accetta solo se il record li porta; senza, si registra il rifiuto invece di
          -- indovinare o di non fare niente in silenzio.
          if coalesce(rec->>'media_type','') = '' or coalesce(rec->>'slot','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            update public.user_favorites set deleted_at = now(), synced_at = now()
            where user_id = v_uid and media_type = rec->>'media_type'
              and slot = (rec->>'slot')::smallint;
          end if;
        end if;

      elsif tbl = 'user_ratings' then
        -- SPEC v3 §3.6/§4: lastWriteWins sulla chiave naturale, che non ha un id sintetico.
        -- L'indice unico e' parziale (solo righe vive), quindi ON CONFLICT non vede la riga
        -- gia' cancellata: prima si prova l'UPDATE — che rianima la lapide riusando la riga,
        -- come il re-follow — e solo se non c'e' niente si inserisce. Mai insert cieco: due
        -- dispositivi che rivotano lo stesso film convergono sulla stessa riga.
        if v_write then
          if coalesce(rec->>'media_type','') = '' or coalesce(rec->>'tmdb_id','') = ''
             or coalesce(rec->>'rating','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            update public.user_ratings t set
              rating = (rec->>'rating')::smallint,
              updated_at = coalesce(nullif(rec->>'updated_at','')::timestamptz, now()),
              deleted_at = nullif(rec->>'deleted_at','')::timestamptz,
              synced_at = now()
            where t.user_id = v_uid
              and t.media_type = rec->>'media_type'
              and t.tmdb_id = (rec->>'tmdb_id')::integer
              and coalesce(t.season_number, -1) = coalesce(nullif(rec->>'season_number','')::integer, -1)
              and coalesce(t.episode_number, -1) = coalesce(nullif(rec->>'episode_number','')::integer, -1);
            if not found then
              insert into public.user_ratings
                (user_id, media_type, tmdb_id, season_number, episode_number, rating,
                 created_at, updated_at, deleted_at, synced_at)
              values
                (v_uid, rec->>'media_type', (rec->>'tmdb_id')::integer,
                 nullif(rec->>'season_number','')::integer, nullif(rec->>'episode_number','')::integer,
                 (rec->>'rating')::smallint,
                 coalesce(nullif(rec->>'created_at','')::timestamptz, now()),
                 coalesce(nullif(rec->>'updated_at','')::timestamptz, now()),
                 nullif(rec->>'deleted_at','')::timestamptz, now());
            end if;
          end if;
        elsif op = 'DELETE' then
          -- Stessa ragione dei favorites: la chiave naturale non entra in `id`, quindi la
          -- DELETE porta la chiave nel record, o e' un rifiuto registrato.
          if coalesce(rec->>'media_type','') = '' or coalesce(rec->>'tmdb_id','') = '' then
            v_handled := false;
            v_reason := 'missing_required_field';
          else
            update public.user_ratings set deleted_at = now(), synced_at = now()
            where user_id = v_uid
              and media_type = rec->>'media_type'
              and tmdb_id = (rec->>'tmdb_id')::integer
              and coalesce(season_number, -1) = coalesce(nullif(rec->>'season_number','')::integer, -1)
              and coalesce(episode_number, -1) = coalesce(nullif(rec->>'episode_number','')::integer, -1);
          end if;
        end if;

      else
        v_handled := false;
        v_reason := 'table_not_handled';
      end if;

      exception
        -- Deterministic: the same payload will fail the same way on every retry, so record it
        -- and move on instead of blocking the queue behind it.
        when data_exception or integrity_constraint_violation then
          v_handled := false;
          v_reason := 'constraint_' || sqlstate;
          v_error := left(sqlerrm, 500);
      end;

      if not v_handled then
        insert into public.sync_rejected_mutations as t
          (user_id, table_name, reason, day, occurrences, last_record_id, last_error, last_seen_at)
        values
          (v_uid, coalesce(tbl,'(null)'), coalesce(v_reason,'unknown'), current_date, 1, rec_id, v_error, now())
        on conflict (user_id, table_name, reason, day) do update set
          occurrences = t.occurrences + 1,
          last_record_id = excluded.last_record_id,
          last_error = excluded.last_error,
          last_seen_at = now();
      end if;

    end loop;
  end;
$$;


ALTER FUNCTION "public"."apply_mutations"("batch" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."award_xp"("p_action_type" "text", "p_source" "text" DEFAULT NULL::"text", "p_is_pro" boolean DEFAULT false, "p_custom_xp" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid := (select auth.uid());
  v_today date := current_date;
  v_state public.user_gamification%rowtype;
  v_base_xp integer;
  v_multiplier real;
  v_streak_bonus integer;
  v_total_xp integer;
  v_new_streak integer;
  v_is_pro boolean;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  -- is_pro derivato server-side (NON dal parametro client, forgeable) E NON da user_daily_quota,
  -- che e' una cache scrivibile dal client. Fonte: user_entitlements, service_role-only.
  select coalesce(e.is_pro, false) into v_is_pro
  from public.user_entitlements e
  where e.user_id = v_uid;
  v_is_pro := coalesce(v_is_pro, false);

  if p_action_type in ('daily_open', 'first_action_of_day', 'streak_day') then
    if exists (
      select 1
      from public.xp_transactions
      where user_id = v_uid
        and action_type = p_action_type
        and action_day = v_today
    ) then
      return jsonb_build_object('awarded', false, 'reason', 'already_awarded_today');
    end if;
  end if;

  select *
  into v_state
  from public.user_gamification
  where user_id = v_uid
  for update;

  v_base_xp := coalesce(p_custom_xp, public.xp_base_for_action(p_action_type));
  if v_base_xp <= 0 then
    return jsonb_build_object('awarded', false, 'reason', 'unknown_action');
  end if;

  v_multiplier := case when v_is_pro then 2.0 else 1.0 end
    * public.streak_multiplier_for_count(coalesce(v_state.current_streak, 0));
  v_streak_bonus := greatest(round(v_base_xp * (public.streak_multiplier_for_count(coalesce(v_state.current_streak, 0)) - 1.0))::integer, 0);
  v_total_xp := round(v_base_xp * v_multiplier)::integer;

  insert into public.xp_transactions(
    user_id, action_type, action_day, base_xp, multiplier, streak_bonus, total_xp, source
  ) values (
    v_uid, p_action_type, v_today, v_base_xp, v_multiplier, v_streak_bonus, v_total_xp, p_source
  )
  on conflict (user_id, action_type, action_day)
  where action_type in ('daily_open', 'first_action_of_day', 'streak_day')
  do nothing;

  if not found then
    return jsonb_build_object('awarded', false, 'reason', 'already_awarded_today');
  end if;

  v_new_streak := public.compute_streak(v_state.last_activity_date, v_today, coalesce(v_state.current_streak, 0));

  insert into public.user_gamification(
    user_id, total_xp, current_level, current_streak, longest_streak,
    last_activity_date, last_daily_open_date, updated_at
  ) values (
    v_uid, v_total_xp, public.level_for_xp(v_total_xp), 1, 1, v_today,
    case when p_action_type = 'daily_open' then v_today else null end, now()
  )
  on conflict (user_id) do update
  set total_xp = public.user_gamification.total_xp + excluded.total_xp,
      current_level = public.level_for_xp(public.user_gamification.total_xp + excluded.total_xp),
      current_streak = v_new_streak,
      longest_streak = greatest(public.user_gamification.longest_streak, v_new_streak),
      last_activity_date = v_today,
      last_daily_open_date = coalesce(excluded.last_daily_open_date, public.user_gamification.last_daily_open_date),
      updated_at = now();

  return jsonb_build_object(
    'awarded', true, 'xp', v_total_xp, 'base_xp', v_base_xp,
    'multiplier', v_multiplier, 'streak_bonus', v_streak_bonus
  );
end $$;


ALTER FUNCTION "public"."award_xp"("p_action_type" "text", "p_source" "text", "p_is_pro" boolean, "p_custom_xp" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."backfill_watchlist_tracking"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
  v_inserted integer := 0;
begin
  for r in
    with ins as (
      insert into public.tv_show_state (user_id, tmdb_show_id, user_status, updated_at)
      select distinct li.user_id, li.media_id, 'active', now()
        from public.list_items li
        join public.lists l on l.id = li.list_id
        -- La join su auth.users e' una cintura: righe orfane di utenti cancellati non devono
        -- far fallire il backfill sulla FK di tv_show_state.
        join auth.users u on u.id = li.user_id
       where l.type = 'watchlist'
         and l.deleted_at is null
         and li.deleted_at is null
         and li.media_type = 'tv'
         and li.media_id > 0
      on conflict (user_id, tmdb_show_id) do nothing
      returning user_id, tmdb_show_id
    )
    select user_id, tmdb_show_id from ins
  loop
    v_inserted := v_inserted + 1;
    -- Le righe nascono a zero: il ricalcolo le allinea agli eventi che l'utente gia' ha (se una
    -- serie in watchlist aveva episodi visti, il bucket giusto non e' not_started).
    perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
  end loop;

  return jsonb_build_object('inserted', v_inserted);
end
$$;


ALTER FUNCTION "public"."backfill_watchlist_tracking"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."backfill_watchlist_tracking"() IS 'Fusione ListsView-Tracking: le serie TV nelle watchlist legacy diventano tv_show_state active ("Da iniziare"). Idempotente (on conflict do nothing): uno stato gia'' scelto non si tocca. Solo service: e'' un lavoro amministrativo, non un''azione utente.';



CREATE OR REPLACE FUNCTION "public"."block_list_owner"("p_list_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  select user_id into v_owner from public.lists where id = p_list_id and deleted_at is null;
  if v_owner is null or v_owner = v_uid then
    return;
  end if;

  insert into public.user_blocks (user_id, blocked_user_id, created_at, synced_at)
  select v_uid, v_owner, now(), now()
  where not exists (
    select 1 from public.user_blocks b
    where b.user_id = v_uid and b.blocked_user_id = v_owner and b.deleted_at is null
  );
end;
$$;


ALTER FUNCTION "public"."block_list_owner"("p_list_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_user"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;
  if p_user_id is null or p_user_id = v_uid then
    raise exception 'invalid_target' using errcode = '23514';
  end if;

  update public.user_blocks set deleted_at = null, synced_at = now()
   where user_id = v_uid and blocked_user_id = p_user_id;
  if not found then
    insert into public.user_blocks (id, user_id, blocked_user_id, synced_at)
    values (gen_random_uuid(), v_uid, p_user_id, now());
  end if;
end $$;


ALTER FUNCTION "public"."block_user"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_quality_score"("p_youtube_views" integer, "p_tmdb_rating" double precision, "p_recency_days" integer) RETURNS double precision
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  view_score FLOAT;
  rating_score FLOAT;
  recency_score FLOAT;
  final_score FLOAT;
BEGIN
  -- View score (0-0.4): Normalize YouTube views (100k+ = max)
  view_score = LEAST(p_youtube_views / 250000.0, 0.4);
  
  -- Rating score (0-0.4): TMDB rating normalized
  rating_score = LEAST((p_tmdb_rating / 10.0) * 0.4, 0.4);
  
  -- Recency score (0-0.2): Newer = better (30 days = max)
  recency_score = LEAST((30.0 - p_recency_days) / 30.0, 1.0) * 0.2;
  recency_score = GREATEST(recency_score, 0);
  
  -- Combine scores
  final_score = view_score + rating_score + recency_score;
  
  RETURN LEAST(final_score, 1.0);
END;
$$;


ALTER FUNCTION "public"."calculate_quality_score"("p_youtube_views" integer, "p_tmdb_rating" double precision, "p_recency_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."catalog_shows_needing_refresh"("p_limit" integer DEFAULT 400) RETURNS TABLE("tmdb_show_id" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select x.tmdb_show_id from (
    -- 1) seguite senza catalogo (self-heal server-side, priorità massima)
    select st.tmdb_show_id, 0 as pri, now() - interval '100 years' as stale_since
      from public.tv_show_state st
      left join public.tmdb_shows s on s.tmdb_show_id = st.tmdb_show_id
     where st.user_status in ('active','for_later') and s.tmdb_show_id is null
    union
    -- 2) seguite con TTL scaduto, o "ended" ferme da >30gg (serie rinnovate dopo la chiusura)
    select st.tmdb_show_id, 1, s.refreshed_at
      from public.tv_show_state st
      join public.tmdb_shows s on s.tmdb_show_id = st.tmdb_show_id
     where st.user_status in ('active','for_later')
       and (s.next_refresh_at <= now() or s.refreshed_at < now() - interval '30 days')
  ) x
  group by x.tmdb_show_id, x.pri
  order by x.pri, min(x.stale_since)
  limit greatest(coalesce(p_limit, 400), 0);
$$;


ALTER FUNCTION "public"."catalog_shows_needing_refresh"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."catalog_store_tvdb_map"("p_rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."catalog_store_tvdb_map"("p_rows" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."catalog_store_tvdb_map"("p_rows" "jsonb") IS 'SPEC v3 §1.5/§6: upsert race-safe della cache TVDB→TMDB; una riga found non viene mai sovrascritta e la risposta contiene le righe effettivamente persistite.';



CREATE OR REPLACE FUNCTION "public"."clean_old_webhook_logs"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM revenuecat_webhook_logs
  WHERE received_at < NOW() - INTERVAL '90 days';
  
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  
  RETURN deleted_count;
END;
$$;


ALTER FUNCTION "public"."clean_old_webhook_logs"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."clean_old_webhook_logs"() IS 'Deletes webhook logs older than 90 days. Run this periodically to manage storage.';



CREATE OR REPLACE FUNCTION "public"."cleanup_expired_cache"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  if to_regclass('public.media_details_cache') is not null then
    delete from public.media_details_cache where expires_at < now();
  end if;
  if to_regclass('public.trailers_cache') is not null then
    delete from public.trailers_cache where cached_at < now() - interval '30 days';
  end if;
end $$;


ALTER FUNCTION "public"."cleanup_expired_cache"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_expired_discovery"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
  delete from public.discovery_warm_feeds where expires_at < now();
$$;


ALTER FUNCTION "public"."cleanup_expired_discovery"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."clip_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "clip_id" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "parent_comment_id" "uuid",
    "content" "text" NOT NULL,
    "like_count" integer DEFAULT 0 NOT NULL,
    "reply_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."clip_comments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "text", "p_comment_id" "text") RETURNS "public"."clip_comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  inserted_row clip_comments;
BEGIN
  INSERT INTO clip_comments (
    id, clip_id, user_id, parent_comment_id, content,
    like_count, reply_count, created_at, updated_at
  )
  VALUES (
    p_comment_id,
    p_clip_id,
    auth.uid(),
    NULLIF(p_parent_comment_id, ''),
    p_content,
    0,
    0,
    timezone('utc', now()),
    timezone('utc', now())
  )
  RETURNING * INTO inserted_row;

  -- Optional: keep clips.comments count in sync server-side
  UPDATE clips
  SET comments = COALESCE(comments, 0) + 1,
      updated_at = timezone('utc', now())
  WHERE clip_id = p_clip_id;

  RETURN inserted_row;
END;
$$;


ALTER FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "text", "p_comment_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "uuid" DEFAULT NULL::"uuid", "p_comment_id" "uuid" DEFAULT "gen_random_uuid"()) RETURNS "public"."clip_comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_comment public.clip_comments;
begin
  if v_user is null then
    raise insufficient_privilege using message = 'User not authenticated';
  end if;

  if trim(coalesce(p_content, '')) = '' then
    raise invalid_parameter_value using message = 'Content cannot be empty';
  end if;

  insert into public.clip_comments (
    id,
    clip_id,
    user_id,
    parent_comment_id,
    content
  )
  values (
    coalesce(p_comment_id, gen_random_uuid()),
    p_clip_id,
    v_user,
    p_parent_comment_id,
    p_content
  )
  returning * into v_comment;

  return v_comment;
end;
$$;


ALTER FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "uuid", "p_comment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_comment_like_count_dec"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  update public.clip_comments
  set like_count = greatest(0, like_count - 1),
      updated_at = now()
  where id = old.comment_id;
  return old;
end;
$$;


ALTER FUNCTION "public"."clip_comment_like_count_dec"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_comment_like_count_inc"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  update public.clip_comments
  set like_count = like_count + 1,
      updated_at = now()
  where id = new.comment_id;
  return new;
end;
$$;


ALTER FUNCTION "public"."clip_comment_like_count_inc"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_comments_clip_count_dec"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  update public.clips
  set comments = greatest(0, comments - 1),
      updated_at = now()
  where clip_id = old.clip_id;
  return old;
end;
$$;


ALTER FUNCTION "public"."clip_comments_clip_count_dec"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_comments_clip_count_inc"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  update public.clips
  set comments = comments + 1,
      updated_at = now()
  where clip_id = new.clip_id;
  return new;
end;
$$;


ALTER FUNCTION "public"."clip_comments_clip_count_inc"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_comments_reply_count_dec"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  if old.parent_comment_id is not null then
    update public.clip_comments
    set reply_count = greatest(0, reply_count - 1),
        updated_at = now()
    where id = old.parent_comment_id;
  end if;
  return old;
end;
$$;


ALTER FUNCTION "public"."clip_comments_reply_count_dec"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_comments_reply_count_inc"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  if new.parent_comment_id is not null then
    update public.clip_comments
    set reply_count = reply_count + 1,
        updated_at = now()
    where id = new.parent_comment_id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."clip_comments_reply_count_inc"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_delete_comment"("p_comment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise insufficient_privilege using message = 'User not authenticated';
  end if;

  delete from public.clip_comments
  where id = p_comment_id
    and user_id = v_user;
end;
$$;


ALTER FUNCTION "public"."clip_delete_comment"("p_comment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "text", "p_like_id" "text") RETURNS TABLE("liked" boolean, "like_count" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  existing_id TEXT;
  v_clip_id TEXT;
BEGIN
  SELECT clip_id INTO v_clip_id FROM clip_comments WHERE id = p_comment_id;

  SELECT id INTO existing_id
  FROM clip_comment_likes
  WHERE comment_id = p_comment_id
    AND user_id = auth.uid();

  IF existing_id IS NULL THEN
    INSERT INTO clip_comment_likes (id, comment_id, user_id, created_at)
    VALUES (p_like_id, p_comment_id, auth.uid(), timezone('utc', now()));
    UPDATE clip_comments
    SET like_count = COALESCE(like_count, 0) + 1,
        updated_at = timezone('utc', now())
    WHERE id = p_comment_id;
    RETURN QUERY SELECT TRUE AS liked,
                        (SELECT COALESCE(like_count, 0) FROM clip_comments WHERE id = p_comment_id) AS like_count;
  ELSE
    DELETE FROM clip_comment_likes
    WHERE id = existing_id;
    UPDATE clip_comments
    SET like_count = GREATEST(COALESCE(like_count, 0) - 1, 0),
        updated_at = timezone('utc', now())
    WHERE id = p_comment_id;
    RETURN QUERY SELECT FALSE AS liked,
                        (SELECT COALESCE(like_count, 0) FROM clip_comments WHERE id = p_comment_id) AS like_count;
  END IF;
END;
$$;


ALTER FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "text", "p_like_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid" DEFAULT "gen_random_uuid"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_existing uuid;
  v_liked boolean := true;
begin
  if v_user is null then
    raise insufficient_privilege using message = 'User not authenticated';
  end if;

  select id into v_existing
  from public.clip_comment_likes
  where comment_id = p_comment_id
    and user_id = v_user
  limit 1;

  if v_existing is not null then
    delete from public.clip_comment_likes where id = v_existing;
    v_liked := false;
  else
    insert into public.clip_comment_likes (id, comment_id, user_id)
    values (coalesce(p_like_id, gen_random_uuid()), p_comment_id, v_user)
    on conflict (comment_id, user_id) do nothing;
    v_liked := true;
  end if;

  return jsonb_build_object(
    'liked', v_liked,
    'like_count', (
      select like_count from public.clip_comments where id = p_comment_id
    )
  );
end;
$$;


ALTER FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "text") RETURNS TABLE("liked" boolean, "like_count" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  existing_id TEXT;
BEGIN
  SELECT id INTO existing_id
  FROM clip_reactions
  WHERE clip_id = p_clip_id
    AND user_id = auth.uid()
    AND reaction_type = 'like';

  IF existing_id IS NULL THEN
    INSERT INTO clip_reactions (id, clip_id, user_id, reaction_type, created_at, updated_at)
    VALUES (p_reaction_id, p_clip_id, auth.uid(), 'like', timezone('utc', now()), timezone('utc', now()));
    UPDATE clips
    SET likes = COALESCE(likes, 0) + 1,
        updated_at = timezone('utc', now())
    WHERE clip_id = p_clip_id;
    RETURN QUERY SELECT TRUE AS liked,
                        (SELECT COALESCE(likes, 0) FROM clips WHERE clip_id = p_clip_id) AS like_count;
  ELSE
    DELETE FROM clip_reactions
    WHERE id = existing_id;
    UPDATE clips
    SET likes = GREATEST(COALESCE(likes, 0) - 1, 0),
        updated_at = timezone('utc', now())
    WHERE clip_id = p_clip_id;
    RETURN QUERY SELECT FALSE AS liked,
                        (SELECT COALESCE(likes, 0) FROM clips WHERE clip_id = p_clip_id) AS like_count;
  END IF;
END;
$$;


ALTER FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "uuid" DEFAULT "gen_random_uuid"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_existing uuid;
  v_liked boolean := true;
begin
  if v_user is null then
    raise insufficient_privilege using message = 'User not authenticated';
  end if;

  select id into v_existing
  from public.clip_reactions
  where clip_id = p_clip_id
    and user_id = v_user
    and reaction_type = 'like'
  limit 1;

  if v_existing is not null then
    delete from public.clip_reactions where id = v_existing;
    v_liked := false;
  else
    insert into public.clip_reactions (id, user_id, clip_id, reaction_type)
    values (coalesce(p_reaction_id, gen_random_uuid()), v_user, p_clip_id, 'like')
    on conflict (user_id, clip_id, reaction_type) do nothing;
    v_liked := true;
  end if;

  return jsonb_build_object(
    'liked', v_liked,
    'like_count', (
      select count(*)
      from public.clip_reactions
      where clip_id = p_clip_id
        and reaction_type = 'like'
    )
  );
end;
$$;


ALTER FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."compute_streak"("p_previous_date" "date", "p_today" "date", "p_current_streak" integer) RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
  select case
    when p_previous_date is null then 1
    when p_previous_date = p_today then greatest(p_current_streak, 1)
    when p_previous_date = p_today - 1 then greatest(p_current_streak, 0) + 1
    else 1
  end
$$;


ALTER FUNCTION "public"."compute_streak"("p_previous_date" "date", "p_today" "date", "p_current_streak" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_default_lists"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
     BEGIN
         -- Try to insert default lists
         BEGIN
             INSERT INTO public.lists (user_id, name, type) VALUES
                 (NEW.id, 'Watchlist', 'Watchlist'),
                 (NEW.id, 'Seen', 'Seen'),
                 (NEW.id, 'Liked', 'Liked'),
                 (NEW.id, 'Disliked', 'Disliked');
         EXCEPTION
             WHEN OTHERS THEN
                 -- Log error but don't fail the signup
                 RAISE WARNING 'Failed to create default lists for user %: %', NEW.id, SQLERRM;
         END;

         RETURN NEW;
     END;
     $$;


ALTER FUNCTION "public"."create_default_lists"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_import_job"("p_storage_path" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid uuid := (select auth.uid());
  v_job uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- Un solo segmento dentro la propria cartella, estensione .zip. Non e' una difesa di
  -- cortesia: le policy del bucket confinano gia' l'upload, ma questa funzione e' definer e
  -- DEVE rifiutare da sola un path altrui — non puo' appoggiarsi a una RLS che non la riguarda.
  if p_storage_path is null
     or p_storage_path !~ ('^' || v_uid::text || '/[^/]+\.zip$') then
    return jsonb_build_object('ok', false, 'reason', 'bad_path');
  end if;

  -- Il file deve esserci davvero, e deve averlo caricato il chiamante. Senza questo controllo
  -- un job nascerebbe `uploaded` su un path vuoto e fallirebbe alla fase 2 con un errore che
  -- parla di storage: la stessa notizia, data piu' tardi e peggio.
  if not exists (
    select 1 from storage.objects o
     where o.bucket_id = 'imports'
       and o.name = p_storage_path
       and (o.owner = v_uid or o.owner_id = v_uid::text)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'upload_not_found');
  end if;

  begin
    insert into public.import_jobs (user_id, source, storage_path)
    values (v_uid, 'tvtime', p_storage_path)
    returning id into v_job;
  exception when unique_violation then
    -- L'indice parziale qui sopra: c'e' gia' un import in corso. Esito, non errore — il client
    -- deve poter dire "ce n'e' uno in corso" senza interpretare un 23505.
    return jsonb_build_object('ok', false, 'reason', 'already_running');
  end;

  return jsonb_build_object('ok', true, 'job_id', v_job);
end;
$_$;


ALTER FUNCTION "public"."create_import_job"("p_storage_path" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_import_job"("p_storage_path" "text") IS 'SPEC v3 §7.2 fase 1: crea il job di import per il chiamante, sul proprio zip gia'' in Storage. Unica scrittura client su import_jobs; le fasi restano del server.';



CREATE OR REPLACE FUNCTION "public"."decay_preference_scores"("p_user_id" "uuid", "p_decay_rate" real DEFAULT 0.95) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    affected_count INTEGER;
BEGIN
    UPDATE public.unified_user_preferences
    SET
        score = score * p_decay_rate,
        score_from_clips = score_from_clips * p_decay_rate,
        score_from_discovery = score_from_discovery * p_decay_rate,
        score_from_search = score_from_search * p_decay_rate,
        score_from_ai = score_from_ai * p_decay_rate,
        score_from_lists = score_from_lists * p_decay_rate,
        last_decay_at = NOW(),
        updated_at = NOW()
    WHERE user_id = p_user_id
        AND (last_decay_at IS NULL OR last_decay_at < NOW() - INTERVAL '7 days');

    GET DIAGNOSTICS affected_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'decayed_count', affected_count,
        'decay_rate', p_decay_rate
    );
END;
$$;


ALTER FUNCTION "public"."decay_preference_scores"("p_user_id" "uuid", "p_decay_rate" real) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."decay_preference_scores"("p_user_id" "uuid", "p_decay_rate" real) IS 'Apply time-based decay to preferences';



CREATE OR REPLACE FUNCTION "public"."delete_activity_comment"("p_comment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  update public.activity_comments c
     set deleted_at = now(), synced_at = now()
   where c.id = p_comment_id
     and c.deleted_at is null
     and (c.user_id = v_uid
          or exists (select 1 from public.activities a
                      where a.id = c.activity_id and a.user_id = v_uid));

  if not found then
    raise exception 'comment_not_available' using errcode = 'P0002';
  end if;
end $$;


ALTER FUNCTION "public"."delete_activity_comment"("p_comment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_custom_list_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_is_pro boolean;
  v_limit  integer;
  v_count  integer;
begin
  -- Le quattro liste core sono strutturali, non "custom": non contano e non vanno mai bloccate.
  if new.type in ('watchlist', 'seen', 'liked', 'disliked') then
    return new;
  end if;

  -- Una riga soft-deletata non occupa uno slot.
  if new.deleted_at is not null then
    return new;
  end if;

  -- Su UPDATE serve solo se la riga sta effettivamente occupando uno slot ORA e non lo faceva prima
  -- (un-delete, o un type che passa da core a custom). Un update qualsiasi su una lista gia attiva
  -- non deve essere bloccato, altrimenti rinominare una lista fallirebbe al limite.
  if tg_op = 'UPDATE'
     and old.deleted_at is null
     and (old.type is null or old.type not in ('watchlist', 'seen', 'liked', 'disliked')) then
    return new;
  end if;

  select coalesce(e.is_pro, false) into v_is_pro
  from public.user_entitlements e
  where e.user_id = new.user_id;

  -- Valori allineati a EntitlementPolicy.maxCustomLists / ListManager.
  v_limit := case when coalesce(v_is_pro, false) then 100 else 2 end;

  select count(*) into v_count
  from public.lists l
  where l.user_id = new.user_id
    and l.deleted_at is null
    and (l.type is null or l.type not in ('watchlist', 'seen', 'liked', 'disliked'))
    and l.id <> new.id;

  if v_count >= v_limit then
    -- Classe 23 di proposito: apply_mutations tratta gli errori deterministici 22/23 come
    -- "registra e salta", quindi il rifiuto finisce in sync_rejected_mutations invece di far
    -- ritentare all'infinito lo stesso payload bloccando la coda.
    raise exception 'custom_list_limit_reached: % lists already, limit is % for this tier', v_count, v_limit
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_custom_list_limit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_is_pro_server_authoritative"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  -- Solo le richieste client non affidabili vengono vincolate.
  if auth.role() in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.is_pro := false;
    elsif tg_op = 'UPDATE' then
      new.is_pro := old.is_pro;
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_is_pro_server_authoritative"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expand_seen_shows_to_watch_events"("p_shows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."expand_seen_shows_to_watch_events"("p_shows" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."expand_seen_shows_to_watch_events"("p_shows" "jsonb") IS 'SPEC v3 blocco 7: espande "serie vista per intero" negli episodi gia'' usciti che il catalogo conosce. Precision inferred, dedup_key legacy:*, rigiocabile.';



CREATE OR REPLACE FUNCTION "public"."get_activity_comments"("p_activity_id" "uuid", "p_limit" integer DEFAULT 50, "p_after" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_after_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("comment_id" "uuid", "user_id" "uuid", "username" "text", "display_name" "text", "avatar_url" "text", "parent_id" "uuid", "content" "text", "is_deleted" boolean, "created_at" timestamp with time zone, "like_count" integer, "liked_by_me" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.activity_interaction_gate(p_activity_id);

  return query
  select
    c.id as comment_id,
    c.user_id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    c.parent_id,
    case when c.deleted_at is not null then null else c.content end as content,
    (c.deleted_at is not null) as is_deleted,
    c.created_at,
    (select count(*)::int from public.activity_comment_likes l
      where l.comment_id = c.id and l.deleted_at is null) as like_count,
    exists(select 1 from public.activity_comment_likes l
            where l.comment_id = c.id and l.user_id = (select auth.uid())
              and l.deleted_at is null) as liked_by_me
  from public.activity_comments c
  join public.profiles p on p.id = c.user_id
  where c.activity_id = p_activity_id
    and (c.deleted_at is null
         or exists (select 1 from public.activity_comments r
                     where r.parent_id = c.id and r.deleted_at is null))
    and (
      c.user_id = (select auth.uid())
      or not exists (
        select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = (select auth.uid()) and b.blocked_user_id = c.user_id)
            or (b.user_id = c.user_id and b.blocked_user_id = (select auth.uid())))
      )
    )
    and (
      c.user_id = (select auth.uid())
      or (select count(distinct cr.reporter_id) from public.content_reports cr
           where cr.content_type = 'activity_comment' and cr.content_id = c.id) < 3
    )
    and (
      p_after is null
      or c.created_at > p_after
      or (c.created_at = p_after and p_after_id is not null and c.id > p_after_id)
    )
  order by c.created_at asc, c.id asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end $$;


ALTER FUNCTION "public"."get_activity_comments"("p_activity_id" "uuid", "p_limit" integer, "p_after" timestamp with time zone, "p_after_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_activity_feed"("p_scope" "text" DEFAULT 'following'::"text", "p_user" "uuid" DEFAULT NULL::"uuid", "p_before" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT 20, "p_activity_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("activity_id" "uuid", "user_id" "uuid", "username" "text", "display_name" "text", "avatar_url" "text", "activity_type" "text", "media_type" "text", "tmdb_id" integer, "episode_count" integer, "rating" smallint, "review_id" "uuid", "review_content" "text", "contains_spoilers" boolean, "list_id" "uuid", "list_name" "text", "list_cover_poster_paths" "text"[], "title" "text", "poster_path" "text", "occurred_at" timestamp with time zone, "like_count" integer, "comment_count" integer, "liked_by_me" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    a.id as activity_id,
    a.user_id,
    p.username::text,
    p.display_name,
    p.avatar_url,
    a.activity_type,
    a.media_type,
    a.tmdb_id,
    a.episode_count,
    a.rating,
    a.review_id,
    case when a.review_id is not null
          and a.user_id <> (select auth.uid())
          and (select count(distinct cr.reporter_id) from public.content_reports cr
                where cr.content_type = 'review' and cr.content_id = a.review_id) >= 3
         then null else v.content end as review_content,
    case when a.review_id is not null
          and a.user_id <> (select auth.uid())
          and (select count(distinct cr.reporter_id) from public.content_reports cr
                where cr.content_type = 'review' and cr.content_id = a.review_id) >= 3
         then null else v.contains_spoilers end as contains_spoilers,
    a.list_id,
    l.name as list_name,
    case when a.list_id is null then null
         else coalesce((
           select array_agg(cov.poster_path order by cov.added_at desc)
           from (
             select li.poster_path, li.added_at
             from public.list_items li
             where li.list_id = a.list_id and li.deleted_at is null and li.poster_path is not null
             order by li.added_at desc
             limit 4
           ) cov
         ), '{}'::text[])
    end as list_cover_poster_paths,
    a.title,
    a.poster_path,
    a.occurred_at,
    (select count(*)::int from public.activity_likes al
      where al.activity_id = a.id and al.deleted_at is null) as like_count,
    (select count(*)::int from public.activity_comments ac
      where ac.activity_id = a.id and ac.deleted_at is null) as comment_count,
    exists(select 1 from public.activity_likes al
            where al.activity_id = a.id and al.user_id = (select auth.uid())
              and al.deleted_at is null) as liked_by_me
  from public.activities a
  join public.profiles p on p.id = a.user_id
  left join public.user_reviews v on v.id = a.review_id and v.deleted_at is null
  left join public.lists l on l.id = a.list_id and l.deleted_at is null
  where a.deleted_at is null
    and a.hidden_at is null
    and (
      a.user_id = (select auth.uid())
      or (p.deleted_at is null
          and p.username is not null
          and p.is_profile_public
          and p.activity_feed_enabled
          and p.feed_activated_at is not null)
    )
    and (
      a.user_id = (select auth.uid())
      or not exists (
        select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = (select auth.uid()) and b.blocked_user_id = a.user_id)
            or (b.user_id = a.user_id and b.blocked_user_id = (select auth.uid())))
      )
    )
    and (
      a.activity_type <> 'list_created'
      or a.user_id = (select auth.uid())
      or (select count(distinct r.user_id) from public.list_reports r where r.list_id = a.list_id) < 3
    )
    and (a.activity_type <> 'list_created' or (l.id is not null and l.is_public))
    and (p_activity_id is null or a.id = p_activity_id)
    and (
      p_activity_id is not null
      or case p_scope
           when 'community' then true
           when 'user' then a.user_id = p_user
           else a.user_id = (select auth.uid())
                or exists (
                  select 1 from public.user_follows f
                  where f.follower_id = (select auth.uid())
                    and f.followee_id = a.user_id
                    and f.deleted_at is null
                )
         end
    )
    and (
      p_activity_id is not null
      or p_before is null
      or a.occurred_at < p_before
      or (a.occurred_at = p_before and p_before_id is not null and a.id < p_before_id)
    )
  order by a.occurred_at desc, a.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;


ALTER FUNCTION "public"."get_activity_feed"("p_scope" "text", "p_user" "uuid", "p_before" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer, "p_activity_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_activity_feed"("p_scope" "text", "p_user" "uuid", "p_before" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer, "p_activity_id" "uuid") IS 'Social feed M3: come la M2 (conteggi veri, velo sulle review a >=3 report) più le card nascoste escluse (activities.hidden_at) e p_activity_id per la singola card del deep link, che salta scope e cursore ma non il gate.';



CREATE OR REPLACE FUNCTION "public"."get_ai_global_tokens_today"() RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(
    (SELECT total_tokens FROM public.ai_global_usage WHERE usage_date = CURRENT_DATE),
    0
  );
$$;


ALTER FUNCTION "public"."get_ai_global_tokens_today"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_ai_token_usage"("p_user_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  used integer;
BEGIN
  SELECT request_count INTO used
  FROM public.user_ai_token_usage
  WHERE user_id = p_user_id AND usage_date = CURRENT_DATE;

  RETURN COALESCE(used, 0);
END;
$$;


ALTER FUNCTION "public"."get_ai_token_usage"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_list_items_with_providers"("p_list_id" "uuid", "p_country" "text") RETURNS TABLE("item" "jsonb", "providers" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
  select
    to_jsonb(li.*) as item,
    coalesce(
      jsonb_agg(to_jsonb(ma.*)) filter (where ma.id is not null),
      '[]'::jsonb
    ) as providers
  from public.lists l
  join public.list_items li
    on li.list_id = l.id
   and li.deleted_at is null
   and li.user_id = l.user_id
  left join public.media_availability ma
    on ma.media_id = li.media_id
   and ma.media_type = li.media_type
   and ma.country_code = p_country
  where l.id = p_list_id
    and l.deleted_at is null
    and (
      l.user_id = (select auth.uid())
      or (
        l.is_public
        and not exists (
          select 1 from public.user_blocks b
          where b.user_id = (select auth.uid())
            and b.blocked_user_id = l.user_id
            and b.deleted_at is null
        )
        and (select count(distinct r.user_id) from public.list_reports r where r.list_id = l.id) < 3
      )
    )
  group by li.id;
$$;


ALTER FUNCTION "public"."get_list_items_with_providers"("p_list_id" "uuid", "p_country" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_stats"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  with mine as (
    select media_type, tmdb_movie_id, tmdb_show_id, season_number, episode_number,
           runtime_seconds
    from public.watch_events
    where user_id = (select auth.uid()) and deleted_at is null
  ),
  tv as (
    select m.tmdb_show_id, m.season_number, m.episode_number,
           coalesce(m.runtime_seconds, ep.runtime_minutes * 60, 0) as secs
    from mine m
    left join public.tmdb_episodes ep
      on ep.tmdb_show_id = m.tmdb_show_id
     and ep.season_number = m.season_number
     and ep.episode_number = m.episode_number
    where m.media_type = 'tv'
  ),
  mv as (
    select tmdb_movie_id, coalesce(runtime_seconds, 0) as secs
    from mine
    where media_type = 'movie'
  ),
  mv_extra as (
    select s.tmdb_movie_id, s.secs
    from (
      select li.media_id as tmdb_movie_id,
             max(coalesce(li.runtime, 0)) * 60 as secs
      from public.list_items li
      join public.lists l on l.id = li.list_id
      where l.user_id = (select auth.uid())
        and l.type = 'seen'
        and l.deleted_at is null
        and li.deleted_at is null
        and li.media_type = 'movie'
      group by 1
    ) s
    where not exists (select 1 from mv where mv.tmdb_movie_id = s.tmdb_movie_id)
  ),
  per_show as (
    select tmdb_show_id, sum(secs) as secs
    from tv group by 1
  ),
  gen as (
    select g.genre_id, count(*) as shows, sum(ps.secs)::bigint as secs
    from per_show ps
    join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
    cross join lateral unnest(coalesce(s.genres, '{}')) as g(genre_id)
    group by 1
  ),
  dec as (
    select (extract(year from s.first_air_date)::int / 10) * 10 as decade,
           count(*) as shows, sum(ps.secs)::bigint as secs
    from per_show ps
    join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
    where s.first_air_date is not null
    group by 1
  ),
  voti as (
    select rating, count(*) as n
    from public.user_ratings
    where user_id = (select auth.uid()) and deleted_at is null
    group by 1
  )
  select jsonb_build_object(
    'watch_time_seconds',
      coalesce((select sum(secs) from tv), 0)
        + coalesce((select sum(secs) from mv), 0)
        + coalesce((select sum(secs) from mv_extra), 0),
    'episodes_watched',
      (select count(distinct (tmdb_show_id, season_number, episode_number)) from tv),
    'shows_watched', (select count(distinct tmdb_show_id) from tv),
    'movies_watched',
      (select count(distinct tmdb_movie_id) from mv)
        + (select count(*) from mv_extra),
    'ratings_given',
      (select count(*) from public.user_ratings
        where user_id = (select auth.uid()) and deleted_at is null),

    'per_genere',
      (select coalesce(jsonb_agg(jsonb_build_object(
                'genre_id', genre_id, 'shows', shows, 'seconds', secs)
               order by secs desc, genre_id), '[]'::jsonb) from gen),
    'per_decade',
      (select coalesce(jsonb_agg(jsonb_build_object(
                'decade', decade, 'shows', shows, 'seconds', secs)
               order by decade), '[]'::jsonb) from dec),
    'voti_distribuzione',
      (select coalesce(jsonb_agg(jsonb_build_object('rating', rating, 'count', n)
               order by rating), '[]'::jsonb) from voti),
    'shows_senza_genere',
      (select count(*) from per_show ps
        join public.tmdb_shows s on s.tmdb_show_id = ps.tmdb_show_id
        where s.genres is null or array_length(s.genres, 1) is null)
  );
$$;


ALTER FUNCTION "public"."get_my_stats"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_my_stats"() IS 'SPEC v3 §9.3: le stats del proprietario — totali (base) e ripartizioni genere/decade/voti (§10 Pro, gating in UI). Runtime reali (§13.7), security invoker: decide la RLS.';



CREATE OR REPLACE FUNCTION "public"."get_personalized_recommendations"("p_user_id" "uuid", "p_limit" integer DEFAULT 20) RETURNS TABLE("preference_category" "text", "preference_id" "text", "preference_name" "text", "score" real, "last_interaction_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    v_uid uuid := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'unauthenticated';
    END IF;
    RETURN QUERY
    SELECT
        up.preference_category,
        up.preference_id,
        up.preference_name,
        up.score,
        up.last_interaction_at
    FROM public.unified_user_preferences up
    WHERE up.user_id = v_uid
        AND up.score > 0
    ORDER BY up.score DESC, up.last_interaction_at DESC
    LIMIT p_limit;
END;
$$;


ALTER FUNCTION "public"."get_personalized_recommendations"("p_user_id" "uuid", "p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_personalized_recommendations"("p_user_id" "uuid", "p_limit" integer) IS 'Get personalized recommendations';



CREATE OR REPLACE FUNCTION "public"."get_public_lists"("p_search" "text" DEFAULT NULL::"text", "p_scope" "text" DEFAULT 'explore'::"text", "p_limit" integer DEFAULT 20, "p_offset" integer DEFAULT 0, "p_owner" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "type" "text", "updated_at" timestamp with time zone, "item_count" integer, "cover_poster_paths" "text"[], "follower_count" integer, "is_following" boolean, "owner_id" "uuid", "owner_username" "text", "owner_display_name" "text", "owner_avatar_url" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    l.id, l.name, l.description, l.type, l.updated_at,
    (select count(*)::int
       from public.list_items li
      where li.list_id = l.id and li.deleted_at is null) as item_count,
    coalesce((
      select array_agg(cov.poster_path order by cov.added_at desc)
      from (
        select li.poster_path, li.added_at
        from public.list_items li
        where li.list_id = l.id and li.deleted_at is null and li.poster_path is not null
        order by li.added_at desc
        limit 4
      ) cov
    ), '{}'::text[]) as cover_poster_paths,
    (select count(*)::int
       from public.list_follows f
      where f.list_id = l.id and f.deleted_at is null) as follower_count,
    exists(
      select 1 from public.list_follows f
      where f.list_id = l.id and f.user_id = (select auth.uid()) and f.deleted_at is null
    ) as is_following,
    pp.id as owner_id,
    pp.username::text as owner_username,
    pp.display_name as owner_display_name,
    pp.avatar_url as owner_avatar_url
  from public.lists l
  left join public.public_profiles pp on pp.id = l.user_id
  where l.is_public
    and l.deleted_at is null
    and (p_owner is null or l.user_id = p_owner)
    and (p_search is null or p_search = '' or l.name ilike '%' || p_search || '%')
    and not exists (
      select 1 from public.user_blocks b
      where b.deleted_at is null
        and ((b.user_id = (select auth.uid()) and b.blocked_user_id = l.user_id)
          or (b.user_id = l.user_id and b.blocked_user_id = (select auth.uid())))
    )
    and (
      l.user_id = (select auth.uid())
      or (select count(distinct r.user_id) from public.list_reports r where r.list_id = l.id) < 3
    )
    and (
      p_scope is distinct from 'followed'
      or exists (
        select 1 from public.list_follows f
        where f.list_id = l.id and f.user_id = (select auth.uid()) and f.deleted_at is null
      )
    )
  order by follower_count desc, l.updated_at desc
  limit greatest(coalesce(p_limit, 20), 0)
  offset greatest(coalesce(p_offset, 0), 0);
$$;


ALTER FUNCTION "public"."get_public_lists"("p_search" "text", "p_scope" "text", "p_limit" integer, "p_offset" integer, "p_owner" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_public_lists"("p_search" "text", "p_scope" "text", "p_limit" integer, "p_offset" integer, "p_owner" "uuid") IS 'Feed delle liste pubbliche (Explore/Followed), le liste di un utente (p_owner) e, dal social feed M1, l''identita'' dell''autore da public_profiles (null se profilo privato). Definer per escludere i blocchi nei due versi.';



CREATE OR REPLACE FUNCTION "public"."get_public_profile"("p_username" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case when pp.id is null then jsonb_build_object('found', false)
  else jsonb_build_object(
    'found', true,
    'id', pp.id,
    'username', pp.username,
    'display_name', pp.display_name,
    'avatar_url', pp.avatar_url,
    'bio', pp.bio,
    'created_at', pp.created_at,
    'followers', (select count(*) from public.user_follows f
                   where f.followee_id = pp.id and f.deleted_at is null),
    'following', (select count(*) from public.user_follows f
                   where f.follower_id = pp.id and f.deleted_at is null),
    'is_following', exists (select 1 from public.user_follows f
                             where f.follower_id = (select auth.uid())
                               and f.followee_id = pp.id and f.deleted_at is null),
    'follows_me', exists (select 1 from public.user_follows f
                           where f.follower_id = pp.id
                             and f.followee_id = (select auth.uid()) and f.deleted_at is null),
    -- §9.3: due righe da 4, la parte pubblica del profilo. La RLS di user_favorites e'
    -- owner-only apposta: la superficie pubblica e' QUESTO definer, non un grant. Solo slot e
    -- tmdb_id — titoli e poster sono catalogo pubblico, li risolve il client.
    'favorites', jsonb_build_object(
      'movie', coalesce((select jsonb_agg(jsonb_build_object('slot', f.slot, 'tmdb_id', f.tmdb_id)
                                          order by f.slot)
                           from public.user_favorites f
                          where f.user_id = pp.id and f.media_type = 'movie'
                            and f.deleted_at is null), '[]'::jsonb),
      'tv', coalesce((select jsonb_agg(jsonb_build_object('slot', f.slot, 'tmdb_id', f.tmdb_id)
                                       order by f.slot)
                        from public.user_favorites f
                       where f.user_id = pp.id and f.media_type = 'tv'
                         and f.deleted_at is null), '[]'::jsonb)))
  end
  from (select 1) as one
  left join public.public_profiles pp
    -- text = lower(...) e non citext = citext: con `search_path = public` l'operatore citext
    -- (schema extensions) non si risolve e Postgres ripiega su text=text, sensibile alle
    -- maiuscole. Il CHECK su profiles garantisce lo username minuscolo, quindi abbassare
    -- l'input equivale al confronto citext — e non dipende dal search_path.
    on pp.username::text = lower(btrim(coalesce(p_username, '')))
   and not exists (
     select 1 from public.user_blocks b
      where b.deleted_at is null
        and ((b.user_id = (select auth.uid()) and b.blocked_user_id = pp.id)
          or (b.user_id = pp.id and b.blocked_user_id = (select auth.uid())))
   );
$$;


ALTER FUNCTION "public"."get_public_profile"("p_username" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_public_profile"("p_username" "text") IS 'SPEC v3 §9.3: profilo pubblico con contatori, relazione col chiamante e favorites (definer: la RLS di user_favorites e'' owner-only apposta). Bloccato in un verso qualunque = found:false, indistinguibile da inesistente.';



CREATE OR REPLACE FUNCTION "public"."get_user_profile_summary"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    result JSONB;
    v_uid uuid := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'unauthenticated';
    END IF;
    SELECT jsonb_build_object(
        'top_genres', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', preference_id,
                'name', preference_name,
                'score', score,
                'interaction_count', interaction_count
            )), '[]'::jsonb)
            FROM (
                SELECT preference_id, preference_name, score, interaction_count
                FROM public.unified_user_preferences
                WHERE user_id = v_uid AND preference_category = 'genre'
                ORDER BY score DESC
                LIMIT 5
            ) top_genres
        ),
        'top_actors', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', preference_id,
                'name', preference_name,
                'score', score
            )), '[]'::jsonb)
            FROM (
                SELECT preference_id, preference_name, score
                FROM public.unified_user_preferences
                WHERE user_id = v_uid AND preference_category = 'actor'
                ORDER BY score DESC
                LIMIT 5
            ) top_actors
        ),
        'recent_interactions', (
            SELECT COUNT(*)
            FROM public.user_discovery_interactions
            WHERE user_id = v_uid
                AND interacted_at > NOW() - INTERVAL '7 days'
        ),
        'total_searches', (
            SELECT COUNT(*)
            FROM public.user_search_history
            WHERE user_id = v_uid
                AND searched_at > NOW() - INTERVAL '30 days'
        ),
        'ai_conversations', (
            SELECT COUNT(DISTINCT session_id)
            FROM public.ai_conversation_history
            WHERE user_id = v_uid
                AND created_at > NOW() - INTERVAL '30 days'
        )
    ) INTO result;
    RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_user_profile_summary"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_user_profile_summary"("p_user_id" "uuid") IS 'Get user profile summary for sync';



CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
BEGIN
  INSERT INTO public.profiles (
    id, 
    email, 
    display_name, 
    avatar_url, 
    created_at, 
    updated_at,
    daily_clips_watched,
    is_founding_member
  )
  VALUES (
    new.id,
    new.email,
    COALESCE(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    NOW(),
    NOW(),
    0,     -- Default for daily_clips_watched
    false  -- Default for is_founding_member
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = EXCLUDED.email,
    display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
    avatar_url = COALESCE(EXCLUDED.avatar_url, public.profiles.avatar_url),
    updated_at = NOW();

  RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hide_activity"("p_activity_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_rows integer;
begin
  if (select auth.uid()) is null then
    raise exception 'unauthenticated';
  end if;

  update public.activities
     set hidden_at = coalesce(hidden_at, now()),
         updated_at = now()
   where id = p_activity_id
     and user_id = (select auth.uid())
     and deleted_at is null;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end $$;


ALTER FUNCTION "public"."hide_activity"("p_activity_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."hide_activity"("p_activity_id" "uuid") IS 'Social feed M3: toglie dal feed una PROPRIA attività (hidden_at). Idempotente; false se la card non esiste o non è del chiamante.';



CREATE OR REPLACE FUNCTION "public"."import_apply_mutations"("p_user" "uuid", "batch" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_user is null then
    -- Errcode proprio, non il P0001 generico: P0001 e' il codice con cui falliscono le
    -- asserzioni dei test, e un rifiuto che lo condivide non si puo' testare con t.rejects.
    raise exception 'import_apply_mutations: p_user obbligatorio'
      using errcode = '22023'; -- invalid_parameter_value
  end if;

  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user::text, 'role', 'authenticated')::text,
                     true);

  perform public.apply_mutations(batch);
end;
$$;


ALTER FUNCTION "public"."import_apply_mutations"("p_user" "uuid", "batch" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."import_apply_mutations"("p_user" "uuid", "batch" "jsonb") IS 'SPEC v3 §7.2: apply_mutations con l''identita'' del proprietario del job, per il driver dell''import (fase 4 ad app chiusa). Eseguibile solo da service_role: fa fede proacl.';



CREATE OR REPLACE FUNCTION "public"."import_exclude_unresolved"("p_job_id" "uuid", "p_tvdb_series_ids" "text"[] DEFAULT NULL::"text"[], "p_movie_uuids" "text"[] DEFAULT NULL::"text"[], "p_series_titles" "text"[] DEFAULT NULL::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_serie integer := 0;
  v_titoli integer := 0;
  v_film integer := 0;
begin
  if not exists (
    select 1 from public.import_jobs
     where id = p_job_id
       and user_id = auth.uid()
       and phase = 'done'
       and status = 'done'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'job_not_done');
  end if;

  if p_tvdb_series_ids is not null and cardinality(p_tvdb_series_ids) > 0 then
    update public.import_staging
       set status = 'skipped',
           error = 'escluso: utente'
     where job_id = p_job_id
       and status = 'unresolved'
       and raw->>'row_kind' in ('event', 'status', 'favorite')
       and raw->>'tvdb_series_id' = any(p_tvdb_series_ids);
    get diagnostics v_serie = row_count;
  end if;

  if p_series_titles is not null and cardinality(p_series_titles) > 0 then
    update public.import_staging
       set status = 'skipped',
           error = 'escluso: utente'
     where job_id = p_job_id
       and status = 'unresolved'
       and raw->>'row_kind' in ('event', 'status', 'favorite')
       and coalesce(raw->>'tvdb_series_id', '') = ''
       and raw->>'series_name' = any(p_series_titles);
    get diagnostics v_titoli = row_count;
  end if;

  if p_movie_uuids is not null and cardinality(p_movie_uuids) > 0 then
    update public.import_staging
       set status = 'skipped',
           error = 'escluso: utente'
     where job_id = p_job_id
       and raw->>'row_kind' = 'movie'
       and (status = 'unresolved'
            or (status = 'skipped'
                and error is distinct from 'film: gia_in_lista'
                and error is distinct from 'escluso: utente'))
       and raw->>'tvtime_movie_uuid' = any(p_movie_uuids);
    get diagnostics v_film = row_count;
  end if;

  if v_serie + v_titoli + v_film = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_exclude');
  end if;

  return jsonb_build_object(
    'ok', true,
    'righe_serie', v_serie + v_titoli,
    'righe_film', v_film
  );
end;
$$;


ALTER FUNCTION "public"."import_exclude_unresolved"("p_job_id" "uuid", "p_tvdb_series_ids" "text"[], "p_movie_uuids" "text"[], "p_series_titles" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."import_exclude_unresolved"("p_job_id" "uuid", "p_tvdb_series_ids" "text"[], "p_movie_uuids" "text"[], "p_series_titles" "text"[]) IS 'Redesign 2.0 import: esclude dall''inbox "Titoli da verificare" i non riconosciuti che l''utente ha scelto di lasciar perdere (skipped, error=''escluso: utente''). Solo il proprietario, solo a job concluso.';



CREATE OR REPLACE FUNCTION "public"."import_reopen_manual_resolution"("p_job_id" "uuid", "p_tvdb_series_id" bigint, "p_tmdb_show_id" integer, "p_row_indexes" integer[], "p_totals" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."import_reopen_manual_resolution"("p_job_id" "uuid", "p_tvdb_series_id" bigint, "p_tmdb_show_id" integer, "p_row_indexes" integer[], "p_totals" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."import_reopen_manual_resolution"("p_job_id" "uuid", "p_tvdb_series_id" bigint, "p_tmdb_show_id" integer, "p_row_indexes" integer[], "p_totals" "jsonb") IS 'SPEC v3 §7.4: salva la serie scelta, riapre le sole righe dichiarate e riporta il job a resolving in una transazione; nessuna identita'' episodio deriva dai numeri dell''export.';



CREATE OR REPLACE FUNCTION "public"."import_reopen_manual_resolutions"("p_job_id" "uuid", "p_resolutions" "jsonb", "p_row_indexes" integer[], "p_totals" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."import_reopen_manual_resolutions"("p_job_id" "uuid", "p_resolutions" "jsonb", "p_row_indexes" integer[], "p_totals" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."import_reopen_manual_resolutions"("p_job_id" "uuid", "p_resolutions" "jsonb", "p_row_indexes" integer[], "p_totals" "jsonb") IS 'SPEC v3 §7.4: salva un batch di identita'' serie e riapre una sola volta il job in una transazione; gli episodi restano risolti esclusivamente dai loro id TVDB esatti.';



CREATE OR REPLACE FUNCTION "public"."import_report"("p_job_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  with job as (
    select id, user_id, phase, status, totals, created_at, updated_at, error
      from public.import_jobs where id = p_job_id
  ),
  righe as (
    select s.status, s.error, s.raw
      from public.import_staging s
      join job j on j.id = s.job_id
  ),
  eventi as (
    select * from righe where raw->>'row_kind' = 'event'
  ),
  scritti as (
    select * from eventi where status = 'written'
  ),
  -- Gli esclusi dall'utente restano nell'elenco (marcati) ma fuori dai contatori; i
  -- fuori-struttura hanno i loro campi dichiarativi.
  non_riconosciuti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           count(*)                                        as episodi,
           min(raw->>'tvdb_series_id')                     as tvdb_series_id,
           coalesce(
             min(error) filter (where coalesce(error, '') is distinct from 'escluso: utente'),
             min(error),
             'motivo non registrato')                      as motivo,
           bool_and(coalesce(error, '') = 'escluso: utente') as escluso
      from eventi
     where status in ('unresolved', 'skipped')
       and coalesce(error, '') is distinct from 'manuale: fuori_struttura_tmdb'
     group by 1
  ),
  fuori_struttura as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           count(*)                                        as episodi
      from eventi
     where error = 'manuale: fuori_struttura_tmdb'
     group by 1
  ),
  voti as (
    select raw->>'kind' as tipo, count(*) as n
      from righe where raw->>'row_kind' = 'rating'
     group by 1
  ),
  stelle as (
    select * from righe where raw->>'row_kind' = 'rating' and raw->>'kind' = 'star'
  ),
  preferiti as (
    select * from righe where raw->>'row_kind' = 'favorite'
  ),
  film as (
    select * from righe where raw->>'row_kind' = 'movie'
  ),
  film_non_risolti as (
    select coalesce(raw->>'title', '(senza titolo)') as titolo,
           raw->>'movie_kind'                        as tipo,
           min(raw->>'tvtime_movie_uuid')            as tvtime_movie_uuid,
           coalesce(
             min(error) filter (where coalesce(error, '') is distinct from 'escluso: utente'),
             min(error),
             'motivo non registrato')                as motivo,
           bool_and(coalesce(error, '') = 'escluso: utente') as escluso,
           min(raw->>'release_year')                 as anno,
           min(raw->>'happened_at')                  as visto_il
      from film
     where (status = 'unresolved'
        or (status = 'skipped' and error is distinct from 'film: gia_in_lista'))
     group by 1, 2
  ),
  stati as (
    select * from righe where raw->>'row_kind' = 'status'
  ),
  stati_non_risolti as (
    select coalesce(raw->>'series_name', '(senza titolo)') as titolo,
           raw->>'user_status'                             as stato,
           min(raw->>'tvdb_series_id')                     as tvdb_series_id,
           coalesce(
             min(error) filter (where coalesce(error, '') is distinct from 'escluso: utente'),
             min(error),
             'motivo non registrato')                      as motivo,
           bool_and(coalesce(error, '') = 'escluso: utente') as escluso
      from stati
     where (status = 'unresolved'
        or (status = 'skipped' and error is distinct from 'stati: stato_gia_in_app'))
     group by 1, 2
  )
  select jsonb_build_object(
    'job_id',        (select id from job),
    'phase',         (select phase from job),
    'status',        (select status from job),
    'error',         (select error from job),
    'durata_secondi',
        (select extract(epoch from updated_at - created_at)::int from job),

    'episodi_importati', (select count(*) from scritti),
    'serie_importate',
        (select count(distinct raw->>'tvdb_series_id') from scritti),
    'film_supportati',   true,
    'film_importati',
        (select count(*) from film where raw->>'movie_kind' = 'seen' and status = 'written'),
    'film_watchlist_importati',
        (select count(*) from film where raw->>'movie_kind' = 'watchlist' and status = 'written'),
    'film_gia_in_app',
        (select count(*) from film
          where status = 'skipped' and error = 'film: gia_in_lista'),
    'film_non_risolti',
        (select count(*) from film_non_risolti where not escluso),
    'film_non_risolti_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'tipo', tipo, 'motivo', motivo,
                  'tvtime_movie_uuid', tvtime_movie_uuid,
                  'escluso', escluso, 'anno', anno, 'visto_il', visto_il)
                 order by escluso, titolo), '[]'::jsonb)
           from film_non_risolti),

    'dal', (select min(raw->>'watched_at') from scritti),
    'al',  (select max(raw->>'watched_at') from scritti),

    'non_riconosciuti_episodi',
        (select coalesce(sum(episodi), 0) from non_riconosciuti where not escluso),
    'non_riconosciuti_serie',
        (select count(*) from non_riconosciuti where not escluso),
    'non_riconosciuti_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'episodi', episodi,
                  'tvdb_series_id', tvdb_series_id, 'motivo', motivo,
                  'escluso', escluso)
                 order by escluso, episodi desc, titolo), '[]'::jsonb)
           from non_riconosciuti),

    'episodi_fuori_struttura',
        (select coalesce(sum(episodi), 0) from fuori_struttura),
    'fuori_struttura_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'episodi', episodi)
                 order by episodi desc, titolo), '[]'::jsonb)
           from fuori_struttura),

    'voti_stelle',        coalesce((select n from voti where tipo = 'star'), 0),
    'voti_reaction',      coalesce((select n from voti where tipo = 'reaction'), 0),
    'voti_indecodificabili',
                          coalesce((select n from voti where tipo = 'undecodable'), 0),

    'voti_importati',
        (select not exists (
           select 1 from stelle
            where not (status = 'written'
                       or error in ('voti: voto_gia_in_app', 'voti: non_risolto',
                                    'voti: numerazione_mancante', 'voti: voto_fuori_scala',
                                    'voti: senza_episodio')))),
    'voti_stelle_importati',
        (select count(*) from stelle where status = 'written'),
    'voti_stelle_gia_in_app',
        (select count(*) from stelle where error = 'voti: voto_gia_in_app'),
    'voti_stelle_non_risolti',
        (select count(*) from stelle
          where error in ('voti: non_risolto', 'voti: numerazione_mancante',
                          'voti: voto_fuori_scala', 'voti: senza_episodio')),

    'favorites_supportati',   true,
    'favorites_importati',
        (select count(*) from preferiti where status = 'written'),
    'favorites_slot_pieni',
        (select count(*) from preferiti
          where status = 'skipped' and error = 'favorites: slot_pieni'),
    'favorites_gia_in_app',
        (select count(*) from preferiti
          where status = 'skipped' and error = 'favorites: gia_favorito'),
    'favorites_non_risolti',
        (select count(*) from preferiti
          where status = 'unresolved'
             or (status = 'skipped' and error = 'favorites: non_risolto')),
    'favorite_film_non_supportati',
        (select coalesce((totals->>'favorite_movies_unsupported')::int, 0) from job),

    'stati_supportati',   true,
    'stati_serie_importati',
        (select count(*) from stati where status = 'written'),
    'stati_serie_lasciati_in_app',
        (select count(*) from stati
          where status = 'skipped' and error = 'stati: stato_gia_in_app'),
    'stati_serie_non_risolti',
        (select count(*) from stati_non_risolti where not escluso),
    'stati_non_risolti_elenco',
        (select coalesce(jsonb_agg(jsonb_build_object(
                  'titolo', titolo, 'stato', stato,
                  'tvdb_series_id', tvdb_series_id, 'motivo', motivo,
                  'escluso', escluso)
                 order by escluso, titolo), '[]'::jsonb)
           from stati_non_risolti),

    'totali_grezzi',      (select totals from job)
  )
  from job;
$$;


ALTER FUNCTION "public"."import_report"("p_job_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."import_report"("p_job_id" "uuid") IS 'SPEC v3 §7.4 + redesign 2.0: report di fine import. Gli esclusi dall''utente restano nell''elenco marcati (escluso = true) ma fuori dai contatori; i fuori-struttura TMDB hanno i loro campi dichiarativi. security invoker: decide la RLS.';



CREATE OR REPLACE FUNCTION "public"."import_touched_shows"("p_job_id" "uuid", "p_after" integer DEFAULT 0, "p_limit" integer DEFAULT 200) RETURNS SETOF integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select distinct (s.resolved->>'tmdb_show_id')::integer as tmdb_show_id
    from public.import_staging s
   where s.job_id = p_job_id
     and s.status = 'written'
     and s.resolved ? 'tmdb_show_id'
     and (s.resolved->>'tmdb_show_id')::integer > coalesce(p_after, 0)
   order by 1
   limit greatest(1, coalesce(p_limit, 200));
$$;


ALTER FUNCTION "public"."import_touched_shows"("p_job_id" "uuid", "p_after" integer, "p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."import_touched_shows"("p_job_id" "uuid", "p_after" integer, "p_limit" integer) IS 'SPEC v3 §7.2 fase 5: le serie toccate da un job, a blocchi. security definer perche'' la chiama il server con la chiave di servizio, come recompute_tv_show_state.';



CREATE OR REPLACE FUNCTION "public"."imports_stale_uploads"("p_older_than" interval DEFAULT '7 days'::interval) RETURNS TABLE("name" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'imports'
     and o.created_at < now() - p_older_than
     -- Un job aperto tiene in vita il proprio file anche oltre il TTL: la fase 2 lo sta
     -- ancora leggendo, e strapparglielo trasformerebbe la pulizia in una causa di failed.
     -- I job `failed` invece NON lo tengono: il TTL è la promessa di §7.2, e un retry oltre
     -- i 7 giorni risponde `upload_not_found` — visibile, e si risolve ricaricando lo ZIP.
     and not exists (
       select 1 from public.import_jobs j
        where j.status in ('running', 'paused')
          and j.storage_path = o.name
     )
   order by o.created_at
   -- Lavoro limitato per giro: il cron è giornaliero, il residuo passa al giro dopo. La Edge
   -- Function dichiara nel proprio esito se il limite è stato toccato — niente tagli muti.
   limit 200;
$$;


ALTER FUNCTION "public"."imports_stale_uploads"("p_older_than" interval) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."imports_stale_uploads"("p_older_than" interval) IS 'SPEC v3 §7.2: i file del bucket imports oltre il TTL (default 7 giorni), esclusi quelli di job ancora aperti. Solo elenco: la cancellazione la fa imports-cleanup via Storage API.';



CREATE OR REPLACE FUNCTION "public"."increment_clip_views"("clip_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
BEGIN
  UPDATE clips
  SET views = views + 1,
      last_served_at = NOW()
  WHERE id = clip_uuid;
END;
$$;


ALTER FUNCTION "public"."increment_clip_views"("clip_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_special_episode"("season_number" integer) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
  select coalesce(season_number, 0) = 0;
$$;


ALTER FUNCTION "public"."is_special_episode"("season_number" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."level_for_xp"("p_xp" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_level integer := 1;
  v_next integer;
begin
  loop
    exit when v_level >= 50;
    v_next := case
      when v_level + 1 = 1 then 0
      when v_level + 1 between 2 and 5 then v_level * 100
      when v_level + 1 between 6 and 10 then 500 + ((v_level + 1) - 5) * 300
      when v_level + 1 between 11 and 15 then 2000 + ((v_level + 1) - 10) * 600
      when v_level + 1 between 16 and 20 then 5000 + ((v_level + 1) - 15) * 1000
      when v_level + 1 between 21 and 25 then 10000 + ((v_level + 1) - 20) * 2000
      when v_level + 1 between 26 and 30 then 20000 + ((v_level + 1) - 25) * 4000
      when v_level + 1 between 31 and 40 then 40000 + ((v_level + 1) - 30) * 4000
      else 80000 + ((v_level + 1) - 40) * 5000
    end;
    exit when v_next > p_xp;
    v_level := v_level + 1;
  end loop;
  return v_level;
end $$;


ALTER FUNCTION "public"."level_for_xp"("p_xp" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_ai_global_tokens"("p_tokens" integer) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  new_total bigint;
BEGIN
  IF p_tokens IS NULL OR p_tokens < 0 THEN
    RAISE EXCEPTION 'log_ai_global_tokens: p_tokens must be a non-negative integer';
  END IF;

  INSERT INTO public.ai_global_usage (usage_date, total_tokens, last_updated)
  VALUES (CURRENT_DATE, p_tokens, now())
  ON CONFLICT (usage_date)
  DO UPDATE SET
    total_tokens = public.ai_global_usage.total_tokens + EXCLUDED.total_tokens,
    last_updated = now()
  RETURNING total_tokens INTO new_total;

  RETURN new_total;
END;
$$;


ALTER FUNCTION "public"."log_ai_global_tokens"("p_tokens" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_ai_request_usage"("p_user_id" "uuid", "p_bucket" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  new_total integer;
  target_user uuid;
BEGIN
  IF p_bucket IS NULL OR p_bucket NOT IN ('chat', 'aux') THEN
    RAISE EXCEPTION 'log_ai_request_usage: p_bucket must be ''chat'' or ''aux''';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    -- Sessione utente: il parametro e' decorativo, conta solo il JWT.
    target_user := auth.uid();
  ELSIF auth.role() = 'service_role' THEN
    -- cerebras-proxy con client admin: e' lui a sapere per chi sta loggando.
    target_user := p_user_id;
  ELSE
    RAISE EXCEPTION 'log_ai_request_usage: unauthenticated caller';
  END IF;

  IF target_user IS NULL THEN
    RAISE EXCEPTION 'log_ai_request_usage: missing user';
  END IF;

  IF p_bucket = 'chat' THEN
    INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
    VALUES (target_user, CURRENT_DATE, 1, now())
    ON CONFLICT (user_id, usage_date)
    DO UPDATE SET
      request_count = public.user_ai_token_usage.request_count + 1,
      last_updated = now()
    RETURNING request_count INTO new_total;
  ELSE
    INSERT INTO public.user_ai_token_usage (user_id, usage_date, aux_request_count, last_updated)
    VALUES (target_user, CURRENT_DATE, 1, now())
    ON CONFLICT (user_id, usage_date)
    DO UPDATE SET
      aux_request_count = public.user_ai_token_usage.aux_request_count + 1,
      last_updated = now()
    RETURNING aux_request_count INTO new_total;
  END IF;

  RETURN new_total;
END;
$$;


ALTER FUNCTION "public"."log_ai_request_usage"("p_user_id" "uuid", "p_bucket" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_ai_token_usage"("p_user_id" "uuid", "p_requests" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  new_total integer;
BEGIN
  IF p_requests IS NULL OR p_requests < 0 THEN
    RAISE EXCEPTION 'log_ai_token_usage: p_requests must be a non-negative integer';
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'log_ai_token_usage: cannot log requests for another user';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
  VALUES (p_user_id, CURRENT_DATE, p_requests, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET
    request_count = public.user_ai_token_usage.request_count + EXCLUDED.request_count,
    last_updated = now()
  RETURNING request_count INTO new_total;

  RETURN new_total;
END;
$$;


ALTER FUNCTION "public"."log_ai_token_usage"("p_user_id" "uuid", "p_requests" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_user_preferences"("p_user_id" "uuid", "p_preferences" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    pref JSONB;
    merged_count INTEGER := 0;
    updated_count INTEGER := 0;
    new_count INTEGER := 0;
    v_uid uuid := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'unauthenticated';
    END IF;
    FOR pref IN SELECT * FROM jsonb_array_elements(p_preferences)
    LOOP
        INSERT INTO public.unified_user_preferences (
            user_id, device_id, preference_category, preference_id,
            preference_name, score, score_from_clips, score_from_discovery,
            score_from_search, score_from_ai, score_from_lists,
            interaction_count, last_interaction_at, created_at, updated_at
        ) VALUES (
            v_uid,
            pref->>'device_id',
            pref->>'preference_category',
            pref->>'preference_id',
            pref->>'preference_name',
            (pref->>'score')::REAL,
            (pref->>'score_from_clips')::REAL,
            (pref->>'score_from_discovery')::REAL,
            (pref->>'score_from_search')::REAL,
            (pref->>'score_from_ai')::REAL,
            (pref->>'score_from_lists')::REAL,
            (pref->>'interaction_count')::INTEGER,
            (pref->>'last_interaction_at')::TIMESTAMPTZ,
            NOW(),
            NOW()
        )
        ON CONFLICT (user_id, preference_category, preference_id) DO UPDATE SET
            score = public.unified_user_preferences.score + EXCLUDED.score,
            score_from_clips = GREATEST(public.unified_user_preferences.score_from_clips, EXCLUDED.score_from_clips),
            score_from_discovery = GREATEST(public.unified_user_preferences.score_from_discovery, EXCLUDED.score_from_discovery),
            score_from_search = GREATEST(public.unified_user_preferences.score_from_search, EXCLUDED.score_from_search),
            score_from_ai = GREATEST(public.unified_user_preferences.score_from_ai, EXCLUDED.score_from_ai),
            score_from_lists = GREATEST(public.unified_user_preferences.score_from_lists, EXCLUDED.score_from_lists),
            interaction_count = public.unified_user_preferences.interaction_count + EXCLUDED.interaction_count,
            last_interaction_at = GREATEST(public.unified_user_preferences.last_interaction_at, EXCLUDED.last_interaction_at),
            updated_at = NOW();
        GET DIAGNOSTICS merged_count = ROW_COUNT;
        IF merged_count > 0 THEN
            updated_count := updated_count + 1;
        ELSE
            new_count := new_count + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object(
        'success', true,
        'total', jsonb_array_length(p_preferences),
        'updated', updated_count,
        'new', new_count
    );
END;
$$;


ALTER FUNCTION "public"."merge_user_preferences"("p_user_id" "uuid", "p_preferences" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."merge_user_preferences"("p_user_id" "uuid", "p_preferences" "jsonb") IS 'Merge preferences from multiple devices';



CREATE OR REPLACE FUNCTION "public"."prune_user_devices"("p_keep" integer DEFAULT 5) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_deleted integer;
begin
  with ranked as (
    select id, row_number() over (partition by user_id order by updated_at desc) as rn
    from public.user_devices
  )
  delete from public.user_devices d
  using ranked
  where d.id = ranked.id
    and ranked.rn > greatest(p_keep, 1);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;


ALTER FUNCTION "public"."prune_user_devices"("p_keep" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pseudonymize_revenuecat_logs"("p_user_id" "text", "p_pseudonym" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
DECLARE
  affected integer;
BEGIN
  IF p_user_id IS NULL OR p_user_id = '' OR p_pseudonym IS NULL OR p_pseudonym = '' THEN
    RAISE EXCEPTION 'pseudonymize_revenuecat_logs: user id and pseudonym are both required';
  END IF;

  UPDATE revenuecat_webhook_logs
  SET
    app_user_id = p_pseudonym,
    payload = payload
      || jsonb_build_object(
           'app_user_id', to_jsonb(p_pseudonym),
           'original_app_user_id', to_jsonb(p_pseudonym),
           'aliases', jsonb_build_array(to_jsonb(p_pseudonym))
         )
      || CASE
           WHEN jsonb_typeof(payload -> 'subscriber_attributes') = 'object'
           THEN jsonb_build_object(
                  'subscriber_attributes',
                  (payload -> 'subscriber_attributes') - '$email' - '$phoneNumber' - '$displayName'
                )
           ELSE '{}'::jsonb
         END
  WHERE lower(app_user_id) = lower(p_user_id)
     OR lower(payload ->> 'app_user_id') = lower(p_user_id)
     OR lower(payload ->> 'original_app_user_id') = lower(p_user_id)
     OR (
          jsonb_typeof(payload -> 'aliases') = 'array'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(payload -> 'aliases') AS alias
            WHERE lower(alias) = lower(p_user_id)
          )
        );

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$_$;


ALTER FUNCTION "public"."pseudonymize_revenuecat_logs"("p_user_id" "text", "p_pseudonym" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_tv_show_state"("p_user_id" "uuid", "p_tmdb_show_id" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_today date := public.user_today(p_user_id);
  v_specials boolean := public.user_counts_specials(p_user_id);
  -- Il punto raggiunto: l'episodio piu' AVANTI che l'utente ha segnato, non l'ultimo in ordine di
  -- tempo. Chi recupera un vecchio episodio dopo essere arrivato alla stagione 4 non torna
  -- indietro alla stagione 1.
  v_last_season  integer;
  v_last_episode integer;
begin
  select e.season_number, e.episode_number
    into v_last_season, v_last_episode
  from public.watch_events e
  where e.user_id = p_user_id
    and e.tmdb_show_id = p_tmdb_show_id
    and e.deleted_at is null
    and (v_specials or not public.is_special_episode(e.season_number))
  order by e.season_number desc, e.episode_number desc
  limit 1;

  with watched as (
    select distinct e.season_number, e.episode_number
    from public.watch_events e
    where e.user_id = p_user_id
      and e.tmdb_show_id = p_tmdb_show_id
      and e.deleted_at is null
      and (v_specials or not public.is_special_episode(e.season_number))
  ),
  event_stats as (
    select min(e.watched_at) as first_watched_at, max(e.watched_at) as last_watched_at
    from public.watch_events e
    where e.user_id = p_user_id
      and e.tmdb_show_id = p_tmdb_show_id
      and e.deleted_at is null
      and (v_specials or not public.is_special_episode(e.season_number))
  ),
  catalog as (
    select c.season_number, c.episode_number, c.air_date
    from public.tmdb_episodes c
    where c.tmdb_show_id = p_tmdb_show_id
      and (v_specials or not public.is_special_episode(c.season_number))
  ),
  unwatched as (
    select c.* from catalog c
    where not exists (
      select 1 from watched w
      where w.season_number = c.season_number and w.episode_number = c.episode_number
    )
    -- Il cuore della correzione. Confronto per riga: `(3, 2) > (3, 1)` e `(4, 1) > (3, 20)`,
    -- che e' esattamente l'ordine in cui si guarda una serie. Con `v_last_season` null (utente
    -- che non ha ancora visto niente) la condizione cade e vale tutto il catalogo, come prima.
      and (v_last_season is null
           or (c.season_number, c.episode_number) > (v_last_season, v_last_episode))
  ),
  next_any as (      -- anche non ancora uscito: alimenta la timeline
    select * from unwatched order by season_number, episode_number limit 1
  ),
  next_aired as (    -- solo gia' uscito: alimenta backlog_since
    select * from unwatched
    where air_date is not null and air_date <= v_today
    order by season_number, episode_number limit 1
  ),
  counts as (
    select
      -- Gli eventi sono la verita' su cosa l'utente ha visto: si contano anche gli episodi che il
      -- catalogo non conosce (numerazioni divergenti, l'oracolo ne documenta 31 casi su 430).
      (select count(*) from watched)::integer as watched_count,
      (select count(*) from catalog where air_date is not null and air_date <= v_today)::integer as aired_count,
      (select count(*) from catalog)::integer as total_count
  )
  insert into public.tv_show_state as s (
    user_id, tmdb_show_id,
    watched_count, aired_count, total_count,
    last_watched_at, first_watched_at,
    next_season, next_episode, next_air_date,
    backlog_since, completed_at, updated_at
  )
  select
    p_user_id, p_tmdb_show_id,
    c.watched_count, c.aired_count, c.total_count,
    es.last_watched_at, es.first_watched_at,
    na.season_number, na.episode_number, na.air_date,
    case
      when nx.season_number is null then null
      else greatest(nx.air_date::timestamp at time zone 'UTC', es.last_watched_at)
    end,
    case
      when c.total_count > 0 and c.watched_count >= c.total_count then now()
      else null
    end,
    now()
  from counts c
  cross join event_stats es
  left join next_any na on true
  left join next_aired nx on true
  on conflict (user_id, tmdb_show_id) do update set
    watched_count    = excluded.watched_count,
    aired_count      = excluded.aired_count,
    total_count      = excluded.total_count,
    last_watched_at  = excluded.last_watched_at,
    first_watched_at = excluded.first_watched_at,
    next_season      = excluded.next_season,
    next_episode     = excluded.next_episode,
    next_air_date    = excluded.next_air_date,
    backlog_since    = excluded.backlog_since,
    -- La data in cui e' stata finita si conserva: rifinirla non e' finirla di nuovo.
    completed_at     = case when excluded.completed_at is null then null
                            else coalesce(s.completed_at, excluded.completed_at) end,
    updated_at       = now();
    -- user_status resta quello dell'utente, di proposito.
end $$;


ALTER FUNCTION "public"."recompute_tv_show_state"("p_user_id" "uuid", "p_tmdb_show_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_backlog_since"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select s.user_id, s.tmdb_show_id
    from public.tv_show_state s
    where s.user_status in ('active', 'for_later')
      -- `current_date + 1` e non `current_date`: il job gira sull'orologio del server (UTC) ma il
      -- ricalcolo decide con `user_today`, che per un utente a UTC+14 e' gia' il giorno dopo.
      and (s.next_air_date is null or s.next_air_date <= current_date + 1)
  loop
    perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;


ALTER FUNCTION "public"."refresh_backlog_since"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_movie_reaction_counts"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_media_id   integer;
  v_media_type text;
begin
  v_media_id   := coalesce(new.media_id, old.media_id);
  v_media_type := coalesce(new.media_type, old.media_type);

  insert into public.movie_reaction_counts (media_id, media_type, like_count, dislike_count, updated_at)
  select v_media_id,
         v_media_type,
         count(*) filter (where reaction_type = 'like'    and deleted_at is null),
         count(*) filter (where reaction_type = 'dislike' and deleted_at is null),
         now()
    from public.movie_reactions
   where media_id = v_media_id and media_type = v_media_type
  on conflict (media_id, media_type) do update
     set like_count    = excluded.like_count,
         dislike_count = excluded.dislike_count,
         updated_at    = excluded.updated_at;

  return null;
end;
$$;


ALTER FUNCTION "public"."refresh_movie_reaction_counts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_user_device"("p_fcm_token" "text", "p_platform" "text" DEFAULT 'ios'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'User must be authenticated to register device tokens';
  END IF;

  INSERT INTO user_devices (user_id, fcm_token, platform)
  VALUES (auth.uid(), p_fcm_token, COALESCE(NULLIF(p_platform, ''), 'ios'))
  ON CONFLICT (user_id, fcm_token)
  DO UPDATE SET
    platform = EXCLUDED.platform,
    updated_at = NOW();
END;
$$;


ALTER FUNCTION "public"."register_user_device"("p_fcm_token" "text", "p_platform" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_content"("p_content_type" "text", "p_content_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid   uuid := (select auth.uid());
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;
  if p_content_type not in ('review','activity_comment') then
    raise exception 'invalid_content_type' using errcode = '23514';
  end if;

  if p_content_type = 'review' then
    select r.user_id into v_owner from public.user_reviews r
     where r.id = p_content_id and r.deleted_at is null;
  else
    select c.user_id into v_owner from public.activity_comments c
     where c.id = p_content_id and c.deleted_at is null;
  end if;

  if v_owner is null then
    raise exception 'content_not_available' using errcode = 'P0002';
  end if;
  if v_owner = v_uid then
    return;
  end if;

  insert into public.content_reports (reporter_id, content_type, content_id, reason)
  values (v_uid, p_content_type, p_content_id, nullif(btrim(coalesce(p_reason, '')), ''))
  on conflict (reporter_id, content_type, content_id) do nothing;
end $$;


ALTER FUNCTION "public"."report_content"("p_content_type" "text", "p_content_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_ai_token_usage"("p_user_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  target_user uuid := auth.uid();
BEGIN
  IF target_user IS NULL THEN
    RAISE EXCEPTION 'reset_ai_token_usage: unauthenticated caller';
  END IF;

  INSERT INTO public.user_ai_token_usage (user_id, usage_date, request_count, last_updated)
  VALUES (target_user, CURRENT_DATE, 0, now())
  ON CONFLICT (user_id, usage_date)
  DO UPDATE SET request_count = 0, last_updated = now();

  RETURN 0;
END;
$$;


ALTER FUNCTION "public"."reset_ai_token_usage"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_daily_quotas"() RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  rows_updated INTEGER;
BEGIN
  UPDATE user_daily_quota
  SET clips_watched_today = 0,
      last_reset_at = NOW(),
      updated_at = NOW()
  WHERE last_reset_at < CURRENT_DATE;
  
  GET DIAGNOSTICS rows_updated = ROW_COUNT;
  RETURN rows_updated;
END;
$$;


ALTER FUNCTION "public"."reset_daily_quotas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."retry_import_job"("p_job_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
  v_count integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  begin
    update public.import_jobs
       set status = 'running', error = null
     where id = p_job_id
       and user_id = v_uid
       and status = 'failed';
    get diagnostics v_count = row_count;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'already_running');
  end;

  if v_count = 0 then
    -- Job altrui, inesistente o non fallito: per il chiamante e' la stessa risposta. Come per
    -- il login, distinguere sarebbe un oracolo su job che non gli appartengono.
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."retry_import_job"("p_job_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."retry_import_job"("p_job_id" "uuid") IS 'SPEC v3 §7.2: riporta a running un proprio job failed. Checkpoint e dedup_key rendono la ripresa sicura; non distingue "altrui" da "inesistente".';



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "display_name" "text",
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "daily_clips_watched" integer DEFAULT 0,
    "last_clip_date" "date",
    "is_founding_member" boolean DEFAULT false,
    "founding_member_product_id" "text",
    "subscription_canceled_at" timestamp without time zone,
    "fcm_token" "text",
    "has_billing_issue" boolean DEFAULT false,
    "billing_issue_detected_at" timestamp with time zone,
    "is_on_trial" boolean DEFAULT false,
    "trial_started_at" timestamp with time zone,
    "trial_cancelled_at" timestamp with time zone,
    "trial_converted_at" timestamp with time zone,
    "username" "extensions"."citext",
    "bio" "text",
    "is_profile_public" boolean DEFAULT true NOT NULL,
    "username_changed_at" timestamp with time zone,
    "username_confirmed_at" timestamp with time zone,
    "activity_feed_enabled" boolean DEFAULT true NOT NULL,
    "feed_activated_at" timestamp with time zone,
    CONSTRAINT "profiles_bio_length" CHECK ((("bio" IS NULL) OR ("length"("bio") <= 200))),
    CONSTRAINT "profiles_username_format" CHECK ((("username" IS NULL) OR ("username" OPERATOR("extensions".~) '^[a-z0-9_]{3,20}$'::"extensions"."citext")))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."username_confirmed_at" IS 'Quando l''utente ha confermato o scelto il proprio username (§3.7). Null = assegnato dal backfill e mai visto da chi lo porta: e'' il segnale che fa comparire la schermata di scelta.';



COMMENT ON COLUMN "public"."profiles"."activity_feed_enabled" IS 'Social feed M1: toggle "le mie attivita'' nel feed". Default true, ma non fa fede da solo: serve anche feed_activated_at non-null (il consenso esplicito).';



COMMENT ON COLUMN "public"."profiles"."feed_activated_at" IS 'Social feed M1: quando l''utente ha risposto all''annuncio del feed (in qualunque modo). Null = mai risposto = invisibile nel feed, backfill incluso. Si stampa una volta, mai si azzera.';



CREATE OR REPLACE VIEW "public"."public_profiles" WITH ("security_invoker"='off') AS
 SELECT "id",
    "username",
    "display_name",
    "avatar_url",
    "bio",
    "created_at"
   FROM "public"."profiles"
  WHERE (("deleted_at" IS NULL) AND "is_profile_public" AND ("username" IS NOT NULL));


ALTER VIEW "public"."public_profiles" OWNER TO "postgres";


COMMENT ON VIEW "public"."public_profiles" IS 'SPEC v3 §3.7: la sola superficie pubblica del profilo. Niente email ne'' campi di billing.';



CREATE OR REPLACE FUNCTION "public"."search_users"("p_query" "text", "p_limit" integer DEFAULT 20) RETURNS SETOF "public"."public_profiles"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with q as (
    select btrim(coalesce(p_query, '')) as raw,
           replace(replace(replace(btrim(coalesce(p_query, '')),
             '\', '\\'), '%', '\%'), '_', '\_') as esc
  )
  select pp.*
  from public.public_profiles pp, q
  where q.raw <> ''
    and (pp.username::text ilike '%' || q.esc || '%' escape '\'
         or coalesce(pp.display_name, '') ilike '%' || q.esc || '%' escape '\')
    and not exists (
      select 1 from public.user_blocks b
       where b.deleted_at is null
         and ((b.user_id = (select auth.uid()) and b.blocked_user_id = pp.id)
           or (b.user_id = pp.id and b.blocked_user_id = (select auth.uid())))
    )
  order by greatest(extensions.similarity(pp.username::text, q.raw),
                    extensions.similarity(coalesce(pp.display_name, ''), q.raw)) desc,
           pp.username
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;


ALTER FUNCTION "public"."search_users"("p_query" "text", "p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."search_users"("p_query" "text", "p_limit" integer) IS 'SPEC v3 §3.7: ricerca utenti su username e display_name, blocchi esclusi nei due versi. Definer perche'' il verso "mi ha bloccato" e'' invisibile al chiamante; l''identita'' e'' auth.uid(), mai un parametro.';



CREATE OR REPLACE FUNCTION "public"."set_activity_feed_visibility"("p_enabled" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."set_activity_feed_visibility"("p_enabled" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."set_activity_feed_visibility"("p_enabled" boolean) IS 'Social feed M1: risponde all''annuncio o muove il toggle nei settings. Stampa feed_activated_at la prima volta e non lo azzera mai: il consenso e'' un fatto, non uno stato.';



CREATE OR REPLACE FUNCTION "public"."set_clips_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_clips_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_username"("p_username" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid     uuid := (select auth.uid());
  v_attuale extensions.citext;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  select username into v_attuale from public.profiles where id = v_uid;

  -- Confermare quello che si ha gia' e' il caso piu' comune dei 295 del backfill: non e' un
  -- cambio, non tocca username_changed_at, e non deve inciampare nell'indice unico contro se'.
  if v_attuale is not null and v_attuale = p_username::extensions.citext then
    update public.profiles set username_confirmed_at = now() where id = v_uid;
    return jsonb_build_object('ok', true, 'username', v_attuale, 'changed', false);
  end if;

  if p_username is null or p_username !~ '^[a-z0-9_]{3,20}$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_format');
  end if;

  if exists (select 1 from public.username_reserved r where r.name = p_username::extensions.citext) then
    return jsonb_build_object('ok', false, 'reason', 'reserved');
  end if;

  begin
    update public.profiles
       set username = p_username::extensions.citext,
           username_confirmed_at = now()
     where id = v_uid;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'taken');
  end;

  return jsonb_build_object('ok', true, 'username', p_username, 'changed', true);
end $_$;


ALTER FUNCTION "public"."set_username"("p_username" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."set_username"("p_username" "text") IS 'SPEC v3 §3.7: sceglie o conferma il proprio username. Esito, non eccezione, sui casi normali.';



CREATE OR REPLACE FUNCTION "public"."streak_multiplier_for_count"("p_streak" integer) RETURNS real
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
  select case
    when p_streak between 0 and 6 then 1.0
    when p_streak between 7 and 13 then 1.1
    when p_streak between 14 and 29 then 1.25
    else 1.5
  end
$$;


ALTER FUNCTION "public"."streak_multiplier_for_count"("p_streak" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."suggest_username"("p_name" "text", "p_fallback" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_base   text := public.username_seed(p_name);
  v_try    text;
  v_suffix integer := 2;
begin
  if v_base is null or length(v_base) < 3 then
    v_base := public.username_seed(p_fallback);
    if v_base is null or length(v_base) < 3 then v_base := 'user'; end if;
  end if;

  if public.username_available(v_base) then
    return v_base;
  end if;

  loop
    v_try := substring(v_base from 1 for 20 - length(v_suffix::text)) || v_suffix::text;
    exit when public.username_available(v_try);
    v_suffix := v_suffix + 1;
    if v_suffix > 9999 then
      return null;
    end if;
  end loop;

  return v_try;
end $$;


ALTER FUNCTION "public"."suggest_username"("p_name" "text", "p_fallback" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_activity_comments_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_owner  uuid;
  v_title  text;
  v_handle text;
begin
  if new.deleted_at is not null then
    return null;
  end if;

  select a.user_id, a.title into v_owner, v_title
    from public.activities a
   where a.id = new.activity_id and a.deleted_at is null;
  if v_owner is null or v_owner = new.user_id then
    return null;
  end if;

  if exists (
       select 1 from public.notifications n
        where n.user_id = v_owner
          and n.notification_type = 'activity_commented'
          and n.thread_id = 'social:' || new.activity_id
          and n.created_at >= date_trunc('day', now())
     ) then
    return null;
  end if;

  select coalesce('@' || p.username::text, p.display_name)
    into v_handle
    from public.profiles p
   where p.id = new.user_id
     and p.deleted_at is null
     and p.is_profile_public
     and p.username is not null;

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id,
     template_key, template_params)
  values
    (v_owner, 'activity_commented', 'New comment',
     coalesce(v_handle, 'Someone') || ' commented on your activity'
       || coalesce(' about ' || v_title, '') || '.',
     'social', 'social:' || new.activity_id,
     case when v_title is null then 'activity_commented' else 'activity_commented_about' end,
     jsonb_build_object('name', coalesce(v_handle, ''), 'title', coalesce(v_title, '')));

  return null;
end $$;


ALTER FUNCTION "public"."tg_activity_comments_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_activity_likes_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_owner  uuid;
  v_title  text;
  v_handle text;
begin
  if new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null then
    return null;
  end if;

  select a.user_id, a.title into v_owner, v_title
    from public.activities a
   where a.id = new.activity_id and a.deleted_at is null;
  if v_owner is null or v_owner = new.user_id then
    return null;
  end if;

  if exists (
       select 1 from public.notifications n
        where n.user_id = v_owner
          and n.notification_type = 'activity_liked'
          and n.thread_id = 'social:' || new.activity_id
          and n.created_at >= date_trunc('day', now())
     ) then
    return null;
  end if;

  select coalesce('@' || p.username::text, p.display_name)
    into v_handle
    from public.profiles p
   where p.id = new.user_id
     and p.deleted_at is null
     and p.is_profile_public
     and p.username is not null;

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id,
     template_key, template_params)
  values
    (v_owner, 'activity_liked', 'New like',
     coalesce(v_handle, 'Someone') || ' liked your activity'
       || coalesce(' about ' || v_title, '') || '.',
     'social', 'social:' || new.activity_id,
     case when v_title is null then 'activity_liked' else 'activity_liked_about' end,
     jsonb_build_object('name', coalesce(v_handle, ''), 'title', coalesce(v_title, '')));

  return null;
end $$;


ALTER FUNCTION "public"."tg_activity_likes_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_list_items_enroll_alert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_list_type text;
  v_source    text;
  v_country   text;
begin
  if new.deleted_at is not null then
    return null;
  end if;

  select l.type into v_list_type
    from public.lists l
   where l.id = new.list_id
     and l.deleted_at is null;

  if v_list_type is null then
    return null;
  end if;

  v_source := case when v_list_type = 'watchlist' then 'watchlist' else 'custom_list' end;

  select p.country into v_country
    from public.user_notification_preferences p
   where p.user_id = new.user_id;

  insert into public.release_alerts as t
    (user_id, media_id, media_type, source, is_active, country_code, deleted_at)
  values
    (new.user_id, new.media_id, new.media_type, v_source, true, coalesce(v_country, 'IT'), null)
  on conflict (user_id, media_id, media_type) do update
    set is_active  = true,
        deleted_at = null,
        source     = case when t.source = 'notify_me' then t.source else excluded.source end;

  return null;
end $$;


ALTER FUNCTION "public"."tg_list_items_enroll_alert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_list_items_retire_alert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.list_items;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  if tg_op = 'UPDATE' and v_row.deleted_at is null then
    return null;
  end if;

  if exists (
       select 1
         from public.list_items li
         join public.lists l on l.id = li.list_id and l.deleted_at is null
        where li.user_id = v_row.user_id
          and li.media_id = v_row.media_id
          and li.media_type = v_row.media_type
          and li.deleted_at is null
          and li.id <> v_row.id
     ) then
    return null;
  end if;

  update public.release_alerts
     set is_active = false,
         deleted_at = now()
   where user_id = v_row.user_id
     and media_id = v_row.media_id
     and media_type = v_row.media_type
     and source in ('watchlist', 'custom_list')
     and is_active;

  return null;
end $$;


ALTER FUNCTION "public"."tg_list_items_retire_alert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_lists_activities"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.is_public and new.deleted_at is null then
    insert into public.activities as a
      (user_id, activity_type, group_key, list_id, occurred_at)
    values
      (new.user_id, 'list_created', 'list:' || new.id, new.id, now())
    on conflict (user_id, group_key) do update set
      deleted_at = null,
      updated_at = now();
  else
    update public.activities set deleted_at = now(), updated_at = now()
     where user_id = new.user_id and group_key = 'list:' || new.id and deleted_at is null;
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."tg_lists_activities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_profiles_username_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.username is distinct from old.username then
    if new.username is not null
       and exists (select 1 from public.username_reserved r where r.name = new.username) then
      raise exception 'username_reserved' using errcode = '23514';
    end if;
    new.username_changed_at := now();
  else
    new.username_changed_at := old.username_changed_at;
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."tg_profiles_username_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_tv_show_state_activities"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.activities_refresh_completed(new.user_id, new.tmdb_show_id, new.completed_at);
  return null;
end $$;


ALTER FUNCTION "public"."tg_tv_show_state_activities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_user_blocks_prune_follows"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.deleted_at is not null then
    return null;
  end if;
  update public.user_follows f
     set deleted_at = now(), synced_at = now()
   where f.deleted_at is null
     and ((f.follower_id = new.user_id and f.followee_id = new.blocked_user_id)
       or (f.follower_id = new.blocked_user_id and f.followee_id = new.user_id));
  return null;
end $$;


ALTER FUNCTION "public"."tg_user_blocks_prune_follows"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_user_follows_blocked"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.deleted_at is null
     and exists (
       select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = new.follower_id and b.blocked_user_id = new.followee_id)
            or (b.user_id = new.followee_id and b.blocked_user_id = new.follower_id))
     ) then
    raise exception 'follow_blocked' using errcode = '23514';
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."tg_user_follows_blocked"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_user_follows_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_handle text;
  v_name   text;
begin
  if new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' then
    if old.deleted_at is null then
      return null;
    end if;
    if old.deleted_at > now() - interval '7 days' then
      return null;
    end if;
  end if;

  select coalesce('@' || p.username::text, p.display_name)
    into v_handle
    from public.profiles p
   where p.id = new.follower_id
     and p.deleted_at is null
     and p.is_profile_public
     and p.username is not null;

  v_name := coalesce(v_handle, '');

  insert into public.notifications
    (user_id, notification_type, title, body, category, thread_id,
     template_key, template_params)
  values
    (new.followee_id, 'new_follower', 'New follower',
     coalesce(v_handle, 'Someone') || ' started following you on VibeWatch.',
     'social', 'social',
     'new_follower', jsonb_build_object('name', v_name));

  return null;
end $$;


ALTER FUNCTION "public"."tg_user_follows_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_user_ratings_activities"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.activities_refresh_rated(new.user_id, new.media_type, new.tmdb_id);
  return null;
end $$;


ALTER FUNCTION "public"."tg_user_ratings_activities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_user_reviews_activities"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.activities_refresh_rated(new.user_id, new.media_type, new.tmdb_id);
  return null;
end $$;


ALTER FUNCTION "public"."tg_user_reviews_activities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_watch_events_activities"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.source like 'import\_%' escape '\' or new.source = 'bulk_show'
     or new.watched_at_precision = 'inferred' then
    return null;
  end if;

  if new.media_type = 'movie' and new.tmdb_movie_id is not null then
    perform public.activities_refresh_watch(
      new.user_id, 'movie', new.tmdb_movie_id, null, coalesce(new.rewatch_index, 0));
  elsif new.media_type = 'tv' and new.tmdb_show_id is not null then
    perform public.activities_refresh_watch(
      new.user_id, 'tv', new.tmdb_show_id, (new.watched_at at time zone 'utc')::date, null);
    if tg_op = 'UPDATE'
       and (old.watched_at at time zone 'utc')::date <> (new.watched_at at time zone 'utc')::date then
      perform public.activities_refresh_watch(
        new.user_id, 'tv', old.tmdb_show_id, (old.watched_at at time zone 'utc')::date, null);
    end if;
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."tg_watch_events_activities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_watch_events_recompute"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r record;
begin
  if tg_op = 'INSERT' then
    for r in select distinct user_id, tmdb_show_id from changed_rows where tmdb_show_id is not null
    loop
      perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    end loop;
  else
    for r in
      select distinct n.user_id, n.tmdb_show_id
      from changed_rows n join previous_rows o on o.id = n.id
      where n.tmdb_show_id is not null and n.deleted_at is distinct from o.deleted_at
    loop
      perform public.recompute_tv_show_state(r.user_id, r.tmdb_show_id);
    end loop;
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."tg_watch_events_recompute"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."toggle_activity_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("liked" boolean, "like_count" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid      uuid := (select auth.uid());
  v_activity uuid;
  v_author   uuid;
  v_existing uuid;
  v_dead     timestamptz;
begin
  select c.activity_id, c.user_id into v_activity, v_author
    from public.activity_comments c
   where c.id = p_comment_id and c.deleted_at is null;
  if v_activity is null then
    raise exception 'comment_not_available' using errcode = 'P0002';
  end if;

  perform public.activity_interaction_gate(v_activity);

  if v_author <> v_uid and exists (
       select 1 from public.user_blocks b
        where b.deleted_at is null
          and ((b.user_id = v_uid and b.blocked_user_id = v_author)
            or (b.user_id = v_author and b.blocked_user_id = v_uid))
     ) then
    raise exception 'comment_not_available' using errcode = 'P0002';
  end if;

  select l.id, l.deleted_at into v_existing, v_dead
    from public.activity_comment_likes l
   where l.comment_id = p_comment_id and l.user_id = v_uid;

  if v_existing is null then
    insert into public.activity_comment_likes (id, comment_id, user_id, synced_at)
    values (coalesce(p_like_id, gen_random_uuid()), p_comment_id, v_uid, now());
    liked := true;
  elsif v_dead is null then
    update public.activity_comment_likes set deleted_at = now(), synced_at = now()
     where id = v_existing;
    liked := false;
  else
    update public.activity_comment_likes set deleted_at = null, synced_at = now()
     where id = v_existing;
    liked := true;
  end if;

  select count(*)::int into like_count
    from public.activity_comment_likes l
   where l.comment_id = p_comment_id and l.deleted_at is null;

  return next;
end $$;


ALTER FUNCTION "public"."toggle_activity_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."toggle_activity_like"("p_activity_id" "uuid", "p_like_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("liked" boolean, "like_count" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid     uuid := (select auth.uid());
  v_existing uuid;
  v_dead    timestamptz;
begin
  perform public.activity_interaction_gate(p_activity_id);

  select l.id, l.deleted_at into v_existing, v_dead
    from public.activity_likes l
   where l.activity_id = p_activity_id and l.user_id = v_uid;

  if v_existing is null then
    insert into public.activity_likes (id, activity_id, user_id, synced_at)
    values (coalesce(p_like_id, gen_random_uuid()), p_activity_id, v_uid, now());
    liked := true;
  elsif v_dead is null then
    update public.activity_likes set deleted_at = now(), synced_at = now()
     where id = v_existing;
    liked := false;
  else
    update public.activity_likes set deleted_at = null, synced_at = now()
     where id = v_existing;
    liked := true;
  end if;

  select count(*)::int into like_count
    from public.activity_likes l
   where l.activity_id = p_activity_id and l.deleted_at is null;

  return next;
end $$;


ALTER FUNCTION "public"."toggle_activity_like"("p_activity_id" "uuid", "p_like_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_import_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."touch_import_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tv_tracking_bucket"("p_user_status" "text", "p_watched_count" integer, "p_backlog_since" timestamp with time zone, "p_stale_after" interval DEFAULT '30 days'::interval) RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case
    when p_user_status in ('dropped','archived') then p_user_status
    when p_user_status = 'for_later'             then 'for_later'
    when coalesce(p_watched_count, 0) = 0        then 'not_started'
    when p_backlog_since is null                 then 'up_to_date'
    when p_backlog_since >= now() - p_stale_after then 'up_next'
    else 'stale'
  end;
$$;


ALTER FUNCTION "public"."tv_tracking_bucket"("p_user_status" "text", "p_watched_count" integer, "p_backlog_since" timestamp with time zone, "p_stale_after" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unsee_tv_show"("p_tmdb_show_id" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
  v_removed integer;
begin
  -- Ancorata ad auth.uid() come apply_mutations: definer perche' authenticated non ha UPDATE su
  -- watch_events (il modello di scrittura e' la lapide via funzioni, mai la riga diretta).
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  if p_tmdb_show_id is null then
    raise exception 'p_tmdb_show_id is required' using errcode = '22023';
  end if;

  update public.watch_events
     set deleted_at = now(), synced_at = now()
   where user_id = v_uid
     and tmdb_show_id = p_tmdb_show_id
     and deleted_at is null;
  get diagnostics v_removed = row_count;

  insert into public.tv_show_state as t (user_id, tmdb_show_id, user_status, updated_at)
  values (v_uid, p_tmdb_show_id, 'dropped', now())
  on conflict (user_id, tmdb_show_id) do update set
    user_status = 'dropped',
    updated_at  = now();

  -- Il ricalcolo azzera i contatori ora che gli eventi hanno la lapide; user_status non lo
  -- tocca (verificato dal test "il ricalcolo non calpesta la scelta dell'utente").
  perform public.recompute_tv_show_state(v_uid, p_tmdb_show_id);

  return jsonb_build_object('events_removed', v_removed);
end
$$;


ALTER FUNCTION "public"."unsee_tv_show"("p_tmdb_show_id" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."unsee_tv_show"("p_tmdb_show_id" integer) IS 'Fusione ListsView-Tracking: rimuovere una serie dalla lista Seen = lapide su tutti i suoi watch_events + user_status dropped (senza, il ricalcolo la farebbe ricomparire come not_started in watchlist). Ancorata ad auth.uid().';



CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_counts_specials"("p_user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_value boolean;
begin
  select count_specials_in_progress into v_value
  from public.unified_user_preferences where user_id = p_user_id;
  return coalesce(v_value, false);
exception when others then
  return false;   -- default di §1.3: gli speciali non contano
end $$;


ALTER FUNCTION "public"."user_counts_specials"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_storage_objects"("p_user" "uuid") RETURNS TABLE("bucket_id" "text", "name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'storage'
    AS $$
  select o.bucket_id, o.name
    from storage.objects o
   where o.owner = p_user
      or (o.bucket_id = 'imports' and o.name like p_user::text || '/%');
$$;


ALTER FUNCTION "public"."user_storage_objects"("p_user" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."user_storage_objects"("p_user" "uuid") IS 'GDPR: gli oggetti Storage di un utente (owner, piu'' la cartella imports/{id}). Elenca soltanto: cancella la Edge Function delete-user via Storage API. Solo service_role.';



CREATE OR REPLACE FUNCTION "public"."user_today"("p_user_id" "uuid") RETURNS "date"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_timezone text;
begin
  select nullif(timezone, '') into v_timezone
  from public.user_notification_preferences where user_id = p_user_id;
  return (now() at time zone coalesce(v_timezone, 'UTC'))::date;
exception when others then
  return (now() at time zone 'UTC')::date;
end $$;


ALTER FUNCTION "public"."user_today"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."username_available"("p_username" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
  select p_username is not null
     and p_username ~ '^[a-z0-9_]{3,20}$'
     and not exists (select 1 from public.username_reserved r where r.name = p_username::extensions.citext)
     and not exists (
           select 1 from public.profiles p
            where p.username = p_username::extensions.citext and p.deleted_at is null);
$_$;


ALTER FUNCTION "public"."username_available"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."username_seed"("p_name" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select nullif(
    btrim(
      substring(
        btrim(
          regexp_replace(
            regexp_replace(
              regexp_replace(lower(coalesce(p_name, '')), '[\s.\-]+', '_', 'g'),
              '[^a-z0-9_]', '', 'g'),
            '_+', '_', 'g'),
          '_')
        from 1 for 20),
      '_'),
    '');
$$;


ALTER FUNCTION "public"."username_seed"("p_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."username_seed"("p_name" "text") IS 'SPEC v3 §3.6: da un display name allo scheletro di uno username. Unica regola, tre chiamanti.';



CREATE OR REPLACE FUNCTION "public"."xp_base_for_action"("p_action_type" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
  select case p_action_type
    when 'daily_open' then 10
    when 'clip_watched' then 5
    when 'clip_liked' then 2
    when 'comment_posted' then 5
    when 'added_to_list' then 3
    when 'share_content' then 10
    when 'streak_day' then 15
    when 'first_action_of_day' then 5
    else 0
  end
$$;


ALTER FUNCTION "public"."xp_base_for_action"("p_action_type" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "activity_type" "text" NOT NULL,
    "group_key" "text" NOT NULL,
    "media_type" "text",
    "tmdb_id" integer,
    "episode_count" integer,
    "rating" smallint,
    "review_id" "uuid",
    "list_id" "uuid",
    "title" "text",
    "poster_path" "text",
    "occurred_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "hidden_at" timestamp with time zone,
    CONSTRAINT "activities_activity_type_check" CHECK (("activity_type" = ANY (ARRAY['watched'::"text", 'rated'::"text", 'list_created'::"text", 'show_completed'::"text"]))),
    CONSTRAINT "activities_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"]))),
    CONSTRAINT "activities_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 10))),
    CONSTRAINT "activities_shape" CHECK (((("activity_type" = ANY (ARRAY['watched'::"text", 'rated'::"text"])) AND ("media_type" IS NOT NULL) AND ("tmdb_id" IS NOT NULL) AND ("list_id" IS NULL)) OR (("activity_type" = 'list_created'::"text") AND ("list_id" IS NOT NULL) AND ("media_type" IS NULL) AND ("tmdb_id" IS NULL)) OR (("activity_type" = 'show_completed'::"text") AND ("media_type" = 'tv'::"text") AND ("tmdb_id" IS NOT NULL) AND ("list_id" IS NULL))))
);


ALTER TABLE "public"."activities" OWNER TO "postgres";


COMMENT ON TABLE "public"."activities" IS 'Social feed M1: una riga per card del feed, materializzata dai trigger sulle tabelle sorgente. group_key deterministica per (utente, gesto): l''upsert aggiorna la card senza cambiarne l''id (like e commenti M2 si ancorano qui). Import, date inferite e bulk_show non entrano mai. Scrive solo il server (trigger); il client legge via get_activity_feed.';



COMMENT ON COLUMN "public"."activities"."hidden_at" IS 'Social feed M3: l''utente ha tolto QUESTA card dal feed (hide_activity). Diverso da deleted_at, che è la lapide dei trigger quando il gesto sottostante sparisce: i refresh azzerano deleted_at a ogni upsert, hidden_at non lo tocca nessuno.';



CREATE TABLE IF NOT EXISTS "public"."activity_comment_likes" (
    "id" "uuid" NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."activity_comment_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activity_comments" (
    "id" "uuid" NOT NULL,
    "activity_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "parent_id" "uuid",
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "activity_comments_content_check" CHECK ((("char_length"("btrim"("content")) >= 1) AND ("char_length"("btrim"("content")) <= 1000)))
);


ALTER TABLE "public"."activity_comments" OWNER TO "postgres";


COMMENT ON TABLE "public"."activity_comments" IS 'Social feed M2: commenti sulle card, un livello di reply (parent_id). Id client-generated. Si scrive solo via add/delete_activity_comment; legge get_activity_comments (gate + blocchi + report).';



CREATE TABLE IF NOT EXISTS "public"."activity_likes" (
    "id" "uuid" NOT NULL,
    "activity_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."activity_likes" OWNER TO "postgres";


COMMENT ON TABLE "public"."activity_likes" IS 'Social feed M2: like sulle card. Id client-generated (retry idempotente); il toggle e'' una lapide che rivive, mai due righe per (attivita'', utente). Si scrive solo via toggle_activity_like.';



CREATE TABLE IF NOT EXISTS "public"."ai_conversation_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "session_id" "text" NOT NULL,
    "message_type" "text" NOT NULL,
    "content" "text" NOT NULL,
    "query_type" "text",
    "mentioned_media_ids" "jsonb",
    "mentioned_genres" "jsonb",
    "tokens_used" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ai_conversation_history_message_type_check" CHECK (("message_type" = ANY (ARRAY['user'::"text", 'assistant'::"text"])))
);


ALTER TABLE "public"."ai_conversation_history" OWNER TO "postgres";


COMMENT ON TABLE "public"."ai_conversation_history" IS 'AI chatbot conversation history';



CREATE TABLE IF NOT EXISTS "public"."ai_global_usage" (
    "usage_date" "date" NOT NULL,
    "total_tokens" bigint DEFAULT 0 NOT NULL,
    "last_updated" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_global_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."api_proxy_budget" (
    "provider" "text" NOT NULL,
    "scope" "text" NOT NULL,
    "window_start" timestamp with time zone NOT NULL,
    "call_count" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "api_proxy_budget_provider_check" CHECK (("provider" = ANY (ARRAY['youtube'::"text", 'streaming_availability'::"text", 'tmdb'::"text", 'auth_login'::"text"])))
);


ALTER TABLE "public"."api_proxy_budget" OWNER TO "postgres";


COMMENT ON TABLE "public"."api_proxy_budget" IS 'Upstream call counters per provider, per caller and globally, bucketed by time window. Only calls that actually reach the upstream API are counted; cache hits are free.';



CREATE TABLE IF NOT EXISTS "public"."api_proxy_cache" (
    "provider" "text" NOT NULL,
    "cache_key" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "hit_count" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "api_proxy_cache_provider_check" CHECK (("provider" = ANY (ARRAY['youtube'::"text", 'streaming_availability'::"text", 'tmdb'::"text"])))
);


ALTER TABLE "public"."api_proxy_cache" OWNER TO "postgres";


COMMENT ON TABLE "public"."api_proxy_cache" IS 'Shared upstream responses for the API proxies. One cached answer serves every user, instead of each device spending its own quota on the same query.';



CREATE TABLE IF NOT EXISTS "public"."clip_comment_likes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."clip_comment_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clip_reactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "clip_id" "text" NOT NULL,
    "reaction_type" "text" DEFAULT 'like'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "synced_at" timestamp with time zone,
    CONSTRAINT "clip_reactions_reaction_type_check" CHECK (("reaction_type" = 'like'::"text"))
);


ALTER TABLE "public"."clip_reactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "clip_id" "text" NOT NULL,
    "video_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "video_url" "text" NOT NULL,
    "thumbnail_url" "text",
    "movie_id" integer,
    "tv_show_id" integer,
    "media_type" "text",
    "likes" integer DEFAULT 0,
    "comments" integer DEFAULT 0,
    "views" integer DEFAULT 0,
    "genres" "text"[],
    "actors" "text"[],
    "mood" "text",
    "keywords" "text"[],
    "youtube_views" integer DEFAULT 0,
    "tmdb_rating" double precision,
    "quality_score" double precision DEFAULT 0.5,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "fetched_at" timestamp with time zone DEFAULT "now"(),
    "last_served_at" timestamp with time zone,
    "is_active" boolean DEFAULT true,
    "is_premium" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "duration" integer DEFAULT 0,
    "language" "text" DEFAULT 'en'::"text",
    "status" "text" DEFAULT 'active'::"text",
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "country_code" "text",
    "language_code" "text",
    "source_region" "text",
    CONSTRAINT "clips_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])))
);


ALTER TABLE "public"."clips" OWNER TO "postgres";


COMMENT ON COLUMN "public"."clips"."is_active" IS 'Boolean flag for quick filtering of active clips';



COMMENT ON COLUMN "public"."clips"."duration" IS 'Duration of the clip in seconds';



COMMENT ON COLUMN "public"."clips"."language" IS 'Language code of the clip (e.g., en, es)';



COMMENT ON COLUMN "public"."clips"."status" IS 'Current status of the clip (active, pending, etc.)';



COMMENT ON COLUMN "public"."clips"."country_code" IS 'ISO 3166-1 alpha-2 country code (e.g., US, IT, GB)';



COMMENT ON COLUMN "public"."clips"."language_code" IS 'ISO 639-1 language code (e.g., en, it, es)';



COMMENT ON COLUMN "public"."clips"."source_region" IS 'TMDb region parameter used during content fetch';



CREATE TABLE IF NOT EXISTS "public"."content_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reporter_id" "uuid" NOT NULL,
    "content_type" "text" NOT NULL,
    "content_id" "uuid" NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "content_reports_content_type_check" CHECK (("content_type" = ANY (ARRAY['review'::"text", 'activity_comment'::"text"])))
);


ALTER TABLE "public"."content_reports" OWNER TO "postgres";


COMMENT ON TABLE "public"."content_reports" IS 'Social feed M2: segnalazioni su review e commenti del feed. Un reporter conta una volta (unique); 3 distinti nascondono il contenuto ai lettori, mai al proprietario. Si scrive solo via report_content.';



CREATE TABLE IF NOT EXISTS "public"."device_info" (
    "device_id" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_name" "text",
    "device_type" "text",
    "app_version" "text",
    "last_sync_at" timestamp with time zone,
    "last_active_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "device_info_device_type_check" CHECK (("device_type" = ANY (ARRAY['ios'::"text", 'android'::"text", 'web'::"text"])))
);


ALTER TABLE "public"."device_info" OWNER TO "postgres";


COMMENT ON TABLE "public"."device_info" IS 'Device information for multi-device sync';



CREATE TABLE IF NOT EXISTS "public"."discovery_cache" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "content_type" "text" NOT NULL,
    "tmdb_id" integer NOT NULL,
    "title" "text" NOT NULL,
    "overview" "text",
    "poster_path" "text",
    "backdrop_path" "text",
    "vote_average" double precision,
    "release_date" "text",
    "genres" integer[],
    "cached_at" timestamp without time zone DEFAULT "now"(),
    "expires_at" timestamp without time zone DEFAULT ("now"() + '24:00:00'::interval),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."discovery_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."discovery_warm_feeds" (
    "region" "text" NOT NULL,
    "carousel_type" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL
);


ALTER TABLE "public"."discovery_warm_feeds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_send_log" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "email_type" "text" NOT NULL,
    "item_count" integer DEFAULT 1 NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "email_send_log_email_type_check" CHECK (("email_type" = ANY (ARRAY['digest'::"text", 'weekly_recap'::"text", 'fallback'::"text"])))
);


ALTER TABLE "public"."email_send_log" OWNER TO "postgres";


ALTER TABLE "public"."email_send_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."email_send_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."global_discovery_filters" (
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "media_type" "text",
    "runtime_min" integer,
    "runtime_max" integer,
    "rating_min" real,
    "rating_max" real,
    "release_year_start" integer,
    "release_year_end" integer,
    "countries" "jsonb",
    "sort_by" "text",
    "hide_watched" boolean DEFAULT false,
    "hide_disliked" boolean DEFAULT false,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "global_discovery_filters_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text", 'both'::"text"]))),
    CONSTRAINT "global_discovery_filters_rating_max_check" CHECK ((("rating_max" >= (0)::double precision) AND ("rating_max" <= (10)::double precision))),
    CONSTRAINT "global_discovery_filters_rating_min_check" CHECK ((("rating_min" >= (0)::double precision) AND ("rating_min" <= (10)::double precision))),
    CONSTRAINT "global_discovery_filters_sort_by_check" CHECK (("sort_by" = ANY (ARRAY['popularity'::"text", 'rating'::"text", 'release_date'::"text", 'trending'::"text"])))
);


ALTER TABLE "public"."global_discovery_filters" OWNER TO "postgres";


COMMENT ON TABLE "public"."global_discovery_filters" IS 'User-defined global filters for discovery';



CREATE TABLE IF NOT EXISTS "public"."health_check" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "status" "text" DEFAULT 'healthy'::"text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."health_check" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."import_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "source" "text" DEFAULT 'tvtime'::"text" NOT NULL,
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "phase" "text" DEFAULT 'uploaded'::"text" NOT NULL,
    "checkpoint" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "totals" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "storage_path" "text",
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "locked_until" timestamp with time zone,
    CONSTRAINT "import_jobs_phase_check" CHECK (("phase" = ANY (ARRAY['uploaded'::"text", 'parsing'::"text", 'resolving'::"text", 'writing'::"text", 'recomputing'::"text", 'done'::"text"]))),
    CONSTRAINT "import_jobs_source_check" CHECK (("source" = 'tvtime'::"text")),
    CONSTRAINT "import_jobs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'paused'::"text", 'done'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."import_jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."import_staging" (
    "job_id" "uuid" NOT NULL,
    "row_index" integer NOT NULL,
    "raw" "jsonb" NOT NULL,
    "resolved" "jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "error" "text",
    CONSTRAINT "import_staging_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'resolved'::"text", 'written'::"text", 'unresolved'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."import_staging" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."list_follows" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "list_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."list_follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."list_items" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "list_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "poster_path" "text",
    "added_at" timestamp with time zone DEFAULT "now"(),
    "runtime" integer,
    "vote_average" numeric(3,1),
    "vote_count" integer,
    "origin_country" "text"[],
    "release_date" "text",
    "genres" integer[],
    "overview" "text",
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "list_items_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])))
);


ALTER TABLE "public"."list_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."list_reports" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "list_id" "uuid" NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."list_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lists" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "is_public" boolean DEFAULT false NOT NULL,
    "source_list_id" "uuid",
    "source_list_type" "text",
    CONSTRAINT "lists_source_list_type_check" CHECK ((("source_list_type" IS NULL) OR ("source_list_type" = ANY (ARRAY['watchlist'::"text", 'seen'::"text", 'liked'::"text", 'disliked'::"text"])))),
    CONSTRAINT "lists_type_check" CHECK (("type" = ANY (ARRAY['watchlist'::"text", 'seen'::"text", 'liked'::"text", 'disliked'::"text", 'custom'::"text"])))
);


ALTER TABLE "public"."lists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."media_availability" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "provider_id" character varying(255) NOT NULL,
    "provider_name" character varying(255) NOT NULL,
    "country_code" character varying(10) NOT NULL,
    "availability_type" "text" NOT NULL,
    "web_url" "text",
    "price_value" real,
    "price_currency" character varying(10),
    "last_checked_at" timestamp with time zone DEFAULT "now"(),
    "synced_at" timestamp with time zone,
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "last_priority_at" timestamp with time zone,
    CONSTRAINT "media_availability_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"]))),
    CONSTRAINT "media_availability_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'normal'::"text", 'high'::"text"])))
);


ALTER TABLE "public"."media_availability" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."media_details_cache" (
    "tmdb_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "overview" "text",
    "poster_path" "text",
    "backdrop_path" "text",
    "cached_at" timestamp without time zone DEFAULT "now"(),
    "expires_at" timestamp without time zone DEFAULT ("now"() + '7 days'::interval),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."media_details_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."movie_reaction_counts" (
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "like_count" integer DEFAULT 0 NOT NULL,
    "dislike_count" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "movie_reaction_counts_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])))
);


ALTER TABLE "public"."movie_reaction_counts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."movie_reactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "reaction_type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "movie_reactions_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"]))),
    CONSTRAINT "movie_reactions_reaction_type_check" CHECK (("reaction_type" = ANY (ARRAY['like'::"text", 'dislike'::"text"])))
);


ALTER TABLE "public"."movie_reactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_delivery_log" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "delivered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "kind" "text" NOT NULL,
    "notification_count" integer DEFAULT 1 NOT NULL,
    "category" "text",
    CONSTRAINT "notification_delivery_log_kind_check" CHECK (("kind" = ANY (ARRAY['single'::"text", 'digest'::"text"])))
);


ALTER TABLE "public"."notification_delivery_log" OWNER TO "postgres";


ALTER TABLE "public"."notification_delivery_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."notification_delivery_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "media_id" integer,
    "media_type" "text",
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "is_sent" boolean DEFAULT false,
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "notification_type" "text" NOT NULL,
    "synced_at" timestamp with time zone,
    "retry_count" integer DEFAULT 0 NOT NULL,
    "next_retry_at" timestamp with time zone,
    "last_error" "text",
    "category" "text",
    "thread_id" "text",
    "template_key" "text",
    "template_params" "jsonb",
    CONSTRAINT "notification_type_check" CHECK (("notification_type" = ANY (ARRAY['new_availability'::"text", 'new_release'::"text", 'episode_aired'::"text", 'continue_watching'::"text", 'streak_reminder'::"text", 'import_done'::"text", 'new_follower'::"text", 'activity_liked'::"text", 'activity_commented'::"text"])))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."personalized_discovery" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "carousel_type" "text" NOT NULL,
    "carousel_title" "text" NOT NULL,
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "position" integer,
    "score" real,
    "reason" "text",
    "description" "text",
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    CONSTRAINT "personalized_discovery_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])))
);


ALTER TABLE "public"."personalized_discovery" OWNER TO "postgres";


COMMENT ON TABLE "public"."personalized_discovery" IS 'Cached personalized carousel content';



CREATE TABLE IF NOT EXISTS "public"."revenuecat_webhook_logs" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "event_type" "text" NOT NULL,
    "app_user_id" "text" NOT NULL,
    "product_id" "text",
    "payload" "jsonb" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."revenuecat_webhook_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."revenuecat_webhook_logs" IS 'Stores all RevenueCat webhook events for debugging, compliance, and analytics';



CREATE OR REPLACE VIEW "public"."recent_webhook_activity" WITH ("security_invoker"='on') AS
 SELECT "id",
    "event_type",
    "app_user_id",
    "product_id",
    "received_at",
    "processed",
    ("payload" ->> 'event_id'::"text") AS "event_id",
    ("payload" ->> 'purchased_at'::"text") AS "purchased_at",
    ("payload" ->> 'expiration_at'::"text") AS "expiration_at"
   FROM "public"."revenuecat_webhook_logs"
  WHERE ("received_at" > ("now"() - '7 days'::interval))
  ORDER BY "received_at" DESC;


ALTER VIEW "public"."recent_webhook_activity" OWNER TO "postgres";


COMMENT ON VIEW "public"."recent_webhook_activity" IS 'Shows webhook events from the last 7 days with key fields extracted';



CREATE TABLE IF NOT EXISTS "public"."release_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "alert_on_stream" boolean DEFAULT true,
    "alert_on_rent" boolean DEFAULT false,
    "alert_on_buy" boolean DEFAULT false,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source" "text" DEFAULT 'notify_me'::"text" NOT NULL,
    "country_code" "text",
    "providers_filter" integer[],
    "last_notified_at" timestamp with time zone,
    "expires_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "release_alerts_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"]))),
    CONSTRAINT "release_alerts_source_check" CHECK (("source" = ANY (ARRAY['notify_me'::"text", 'watchlist'::"text", 'release_calendar'::"text", 'custom_list'::"text"])))
);


ALTER TABLE "public"."release_alerts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_rejected_mutations" (
    "user_id" "uuid" NOT NULL,
    "table_name" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "day" "date" DEFAULT CURRENT_DATE NOT NULL,
    "occurrences" integer DEFAULT 1 NOT NULL,
    "last_record_id" "text",
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_error" "text"
);


ALTER TABLE "public"."sync_rejected_mutations" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_rejected_mutations" IS 'Mutations apply_mutations refused or did not recognise, aggregated per user/table/reason/day.';



CREATE TABLE IF NOT EXISTS "public"."tmdb_episodes" (
    "tmdb_show_id" integer NOT NULL,
    "season_number" integer NOT NULL,
    "episode_number" integer NOT NULL,
    "tmdb_episode_id" integer,
    "name" "text",
    "air_date" "date",
    "runtime_minutes" integer,
    "still_path" "text",
    "refreshed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tmdb_episodes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tmdb_shows" (
    "tmdb_show_id" integer NOT NULL,
    "name" "text" NOT NULL,
    "first_air_date" "date",
    "last_air_date" "date",
    "status" "text",
    "in_production" boolean,
    "number_of_seasons" integer,
    "number_of_episodes" integer,
    "poster_path" "text",
    "origin_country" "text"[],
    "episode_run_time" integer[],
    "refreshed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "next_refresh_at" timestamp with time zone DEFAULT ("now"() + '7 days'::interval) NOT NULL,
    "genres" integer[]
);


ALTER TABLE "public"."tmdb_shows" OWNER TO "postgres";


COMMENT ON COLUMN "public"."tmdb_shows"."genres" IS 'Id genere TMDB (§9.3 stats avanzate). Null = mai popolato: il refresh del catalogo lo riempie.';



CREATE TABLE IF NOT EXISTS "public"."trailers_cache" (
    "tmdb_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "youtube_id" "text" NOT NULL,
    "trailer_type" "text",
    "name" "text",
    "cached_at" timestamp without time zone,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."trailers_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tv_show_state" (
    "user_id" "uuid" NOT NULL,
    "tmdb_show_id" integer NOT NULL,
    "user_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "watched_count" integer DEFAULT 0 NOT NULL,
    "aired_count" integer DEFAULT 0 NOT NULL,
    "total_count" integer DEFAULT 0 NOT NULL,
    "last_watched_at" timestamp with time zone,
    "next_season" integer,
    "next_episode" integer,
    "next_air_date" "date",
    "backlog_since" timestamp with time zone,
    "first_watched_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "synced_at" timestamp with time zone,
    CONSTRAINT "tv_show_state_user_status_check" CHECK (("user_status" = ANY (ARRAY['active'::"text", 'for_later'::"text", 'dropped'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."tv_show_state" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tvdb_tmdb_map" (
    "tvdb_id" bigint NOT NULL,
    "entity_type" "text" NOT NULL,
    "tmdb_show_id" integer,
    "tmdb_movie_id" integer,
    "season_number" integer,
    "episode_number" integer,
    "resolution" "text" NOT NULL,
    "method" "text" NOT NULL,
    "resolved_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tvdb_tmdb_map_entity_type_check" CHECK (("entity_type" = ANY (ARRAY['series'::"text", 'episode'::"text", 'movie'::"text"]))),
    CONSTRAINT "tvdb_tmdb_map_episode_shape" CHECK ((("resolution" <> 'found'::"text") OR ("entity_type" <> 'episode'::"text") OR (("season_number" IS NOT NULL) AND ("episode_number" IS NOT NULL)))),
    CONSTRAINT "tvdb_tmdb_map_found_points_somewhere" CHECK ((("resolution" <> 'found'::"text") OR ("tmdb_show_id" IS NOT NULL) OR ("tmdb_movie_id" IS NOT NULL))),
    CONSTRAINT "tvdb_tmdb_map_resolution_check" CHECK (("resolution" = ANY (ARRAY['found'::"text", 'not_found'::"text", 'ambiguous'::"text"])))
);


ALTER TABLE "public"."tvdb_tmdb_map" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."unified_user_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "preference_category" "text" NOT NULL,
    "preference_id" "text" NOT NULL,
    "preference_name" "text",
    "score" real DEFAULT 0.0 NOT NULL,
    "score_from_clips" real DEFAULT 0.0,
    "score_from_discovery" real DEFAULT 0.0,
    "score_from_search" real DEFAULT 0.0,
    "score_from_ai" real DEFAULT 0.0,
    "score_from_lists" real DEFAULT 0.0,
    "interaction_count" integer DEFAULT 0,
    "last_interaction_at" timestamp with time zone,
    "last_decay_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "count_specials_in_progress" boolean DEFAULT false NOT NULL,
    CONSTRAINT "unified_user_preferences_preference_category_check" CHECK (("preference_category" = ANY (ARRAY['genre'::"text", 'actor'::"text", 'director'::"text", 'mood'::"text", 'keyword'::"text"])))
);


ALTER TABLE "public"."unified_user_preferences" OWNER TO "postgres";


COMMENT ON TABLE "public"."unified_user_preferences" IS 'Centralized preference scores from all app features';



CREATE TABLE IF NOT EXISTS "public"."user_ai_token_usage" (
    "user_id" "uuid" NOT NULL,
    "usage_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "request_count" integer DEFAULT 0 NOT NULL,
    "last_updated" timestamp with time zone DEFAULT "now"() NOT NULL,
    "synced_at" timestamp with time zone,
    "aux_request_count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."user_ai_token_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_badges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "badge_id" "text" NOT NULL,
    "progress" integer DEFAULT 0 NOT NULL,
    "target" integer NOT NULL,
    "unlocked_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_badges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_blocks" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "blocked_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."user_blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_clip_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "device_id" "text",
    "clip_id" "uuid",
    "watched_at" timestamp with time zone DEFAULT "now"(),
    "watch_duration" double precision,
    "total_duration" double precision,
    "completion_rate" double precision,
    "liked" boolean DEFAULT false,
    "commented" boolean DEFAULT false,
    "shared" boolean DEFAULT false,
    "added_to_list" boolean DEFAULT false,
    "engagement_score" double precision DEFAULT 0,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."user_clip_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_clip_signals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "clip_id" "text" NOT NULL,
    "signal_type" "text" NOT NULL,
    "signal_value" double precision,
    "source" "text",
    "position" integer,
    "session_id" "text",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."user_clip_signals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_daily_challenges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "challenge_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "challenge_type" "text" NOT NULL,
    "challenge_description" "text" NOT NULL,
    "target" integer NOT NULL,
    "progress" integer DEFAULT 0 NOT NULL,
    "xp_reward" integer NOT NULL,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_daily_challenges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_daily_quota" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "device_id" "text",
    "clips_watched_today" integer DEFAULT 0,
    "last_reset_at" timestamp with time zone DEFAULT "now"(),
    "is_pro" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "unique_user_or_device" CHECK (((("user_id" IS NOT NULL) AND ("device_id" IS NULL)) OR (("user_id" IS NULL) AND ("device_id" IS NOT NULL))))
);


ALTER TABLE "public"."user_daily_quota" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_devices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "fcm_token" "text" NOT NULL,
    "platform" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "user_devices_platform_check" CHECK (("platform" = ANY (ARRAY['ios'::"text", 'android'::"text", 'web'::"text"])))
);


ALTER TABLE "public"."user_devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_discovery_interactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "media_id" integer NOT NULL,
    "media_type" "text" NOT NULL,
    "carousel_type" "text" NOT NULL,
    "interaction_type" "text" NOT NULL,
    "interacted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_duration" integer,
    "filter_active" boolean DEFAULT false,
    "filter_config" "jsonb",
    "synced_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_discovery_interactions_interaction_type_check" CHECK (("interaction_type" = ANY (ARRAY['view'::"text", 'click'::"text", 'add_to_list'::"text", 'like'::"text", 'dislike'::"text"]))),
    CONSTRAINT "user_discovery_interactions_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])))
);


ALTER TABLE "public"."user_discovery_interactions" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_discovery_interactions" IS 'Tracks carousel interactions in Discovery tab';



CREATE TABLE IF NOT EXISTS "public"."user_entitlements" (
    "user_id" "uuid" NOT NULL,
    "is_pro" boolean DEFAULT false NOT NULL,
    "source" "text" DEFAULT 'revenuecat'::"text" NOT NULL,
    "verified_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_entitlements" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_entitlements" IS 'Entitlement as reported by RevenueCat. Service-role writes only: no client policy grants INSERT/UPDATE/DELETE. This is what any authorisation decision must read — user_daily_quota.is_pro is a client-maintained cache and is forgeable by design.';



CREATE TABLE IF NOT EXISTS "public"."user_favorites" (
    "user_id" "uuid" NOT NULL,
    "media_type" "text" NOT NULL,
    "slot" smallint NOT NULL,
    "tmdb_id" integer NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "user_favorites_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"]))),
    CONSTRAINT "user_favorites_slot_check" CHECK ((("slot" >= 1) AND ("slot" <= 4)))
);


ALTER TABLE "public"."user_favorites" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_favorites" IS 'SPEC v3 §3.6: 4 slot film + 4 slot serie, separati; slot esplicito perche'' l''ordine conta. Sync: lastWriteWins (§4). Soft delete: uno slot svuotato e'' deleted_at, cosi'' il pull lo porta anche agli altri dispositivi.';



CREATE TABLE IF NOT EXISTS "public"."user_follows" (
    "follower_id" "uuid" NOT NULL,
    "followee_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "user_follows_check" CHECK (("follower_id" <> "followee_id"))
);


ALTER TABLE "public"."user_follows" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_follows" IS 'SPEC v3 §3.6: chi segue chi. Soft delete; il re-follow riusa la riga. Sync: union (§4), mai perdere un follow.';



CREATE TABLE IF NOT EXISTS "public"."user_gamification" (
    "user_id" "uuid" NOT NULL,
    "total_xp" integer DEFAULT 0 NOT NULL,
    "current_level" integer DEFAULT 1 NOT NULL,
    "current_streak" integer DEFAULT 0 NOT NULL,
    "longest_streak" integer DEFAULT 0 NOT NULL,
    "streak_freezes_remaining" integer DEFAULT 0 NOT NULL,
    "last_activity_date" "date",
    "last_daily_open_date" "date",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."user_gamification" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_notification_preferences" (
    "user_id" "uuid" NOT NULL,
    "push_enabled" boolean DEFAULT true NOT NULL,
    "new_availability" boolean DEFAULT true NOT NULL,
    "new_release" boolean DEFAULT true NOT NULL,
    "episode_aired" boolean DEFAULT true NOT NULL,
    "streak_reminder" boolean DEFAULT false NOT NULL,
    "list_milestone" boolean DEFAULT false NOT NULL,
    "price_drop" boolean DEFAULT false NOT NULL,
    "quiet_hours_start" time without time zone,
    "quiet_hours_end" time without time zone,
    "timezone" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "continue_watching" boolean DEFAULT true NOT NULL,
    "new_follower" boolean DEFAULT true NOT NULL,
    "activity_liked" boolean DEFAULT true NOT NULL,
    "activity_commented" boolean DEFAULT true NOT NULL,
    "max_daily_notifications" integer DEFAULT 2 NOT NULL,
    "email_digest_enabled" boolean DEFAULT true NOT NULL,
    "weekly_recap_enabled" boolean DEFAULT true NOT NULL,
    "language" "text" DEFAULT 'en'::"text" NOT NULL,
    "country" "text" DEFAULT 'IT'::"text" NOT NULL,
    CONSTRAINT "user_notification_preferences_max_daily_check" CHECK ((("max_daily_notifications" >= 0) AND ("max_daily_notifications" <= 50)))
);


ALTER TABLE "public"."user_notification_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "device_id" "text",
    "preference_type" "text" NOT NULL,
    "preference_id" "text" NOT NULL,
    "preference_name" "text",
    "score" double precision DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "user_preferences_preference_type_check" CHECK (("preference_type" = ANY (ARRAY['genre'::"text", 'actor'::"text", 'movie'::"text", 'tv_show'::"text"])))
);


ALTER TABLE "public"."user_preferences" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_preferences" IS 'DEPRECATED: use unified_user_preferences. Physical drop is deferred to a later milestone after stable releases.';



CREATE TABLE IF NOT EXISTS "public"."user_ratings" (
    "user_id" "uuid" NOT NULL,
    "media_type" "text" NOT NULL,
    "tmdb_id" integer NOT NULL,
    "season_number" integer,
    "episode_number" integer,
    "rating" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "user_ratings_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text", 'episode'::"text"]))),
    CONSTRAINT "user_ratings_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 10))),
    CONSTRAINT "user_ratings_shape" CHECK (((("media_type" = 'episode'::"text") AND ("season_number" IS NOT NULL) AND ("episode_number" IS NOT NULL)) OR (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])) AND ("season_number" IS NULL) AND ("episode_number" IS NULL))))
);


ALTER TABLE "public"."user_ratings" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_ratings" IS 'SPEC v3 §3.6: voto in mezze stelle, intero 1-10 = 0.5-5.0 (scala Letterboxd), mai float. Coesiste con like/dislike: stelle = giudizio, cuore = "mi rappresenta". Sync: lastWriteWins (§4). Una riga viva per chiave (indice unico parziale); il re-voto dopo una cancellazione riusa la riga via apply_mutations.';



CREATE TABLE IF NOT EXISTS "public"."user_reviews" (
    "id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "media_type" "text" NOT NULL,
    "tmdb_id" integer NOT NULL,
    "content" "text" NOT NULL,
    "contains_spoilers" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "user_reviews_content_check" CHECK ((("char_length"("btrim"("content")) >= 1) AND ("char_length"("btrim"("content")) <= 280))),
    CONSTRAINT "user_reviews_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"])))
);


ALTER TABLE "public"."user_reviews" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_reviews" IS 'Social feed M1: review breve (<=280 char) per titolo, stile Letterboxd. Una sola riga viva per (user, media_type, tmdb_id); id sintetico client-generated perche'' report e activities la referenziano. Sync: lastWriteWins. Soft delete: la lapide viaggia col pull.';



CREATE TABLE IF NOT EXISTS "public"."user_search_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "query" "text" NOT NULL,
    "media_type" "text",
    "result_count" integer,
    "clicked_media_id" integer,
    "clicked_media_title" "text",
    "searched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "relevance_score" real DEFAULT 1.0,
    "synced_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_search_history_media_type_check" CHECK ((("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text", 'person'::"text"])) OR ("media_type" IS NULL)))
);


ALTER TABLE "public"."user_search_history" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_search_history" IS 'Tracks user search queries for personalization';



CREATE TABLE IF NOT EXISTS "public"."username_reserved" (
    "name" "extensions"."citext" NOT NULL
);


ALTER TABLE "public"."username_reserved" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_cache_hit_rate" WITH ("security_invoker"='on') AS
 SELECT 'media_availability'::"text" AS "cache_name",
    "count"(*) AS "row_count",
    "count"(*) FILTER (WHERE ("last_checked_at" >= ("now"() - '7 days'::interval))) AS "fresh_rows"
   FROM "public"."media_availability";


ALTER VIEW "public"."v_cache_hit_rate" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_notifications_health" WITH ("security_invoker"='on') AS
 SELECT "count"(*) AS "total_notifications",
    "count"(*) FILTER (WHERE ("is_sent" = true)) AS "sent_notifications",
        CASE
            WHEN ("count"(*) = 0) THEN 1.0
            ELSE (("count"(*) FILTER (WHERE ("is_sent" = true)))::numeric / ("count"(*))::numeric)
        END AS "success_rate",
    "percentile_disc"((0.5)::double precision) WITHIN GROUP (ORDER BY ("sent_at" - "created_at")) AS "p50_delivery_latency",
    "percentile_disc"((0.95)::double precision) WITHIN GROUP (ORDER BY ("sent_at" - "created_at")) AS "p95_delivery_latency",
    "max"("retry_count") AS "max_retry_count"
   FROM "public"."notifications"
  WHERE ("created_at" >= ("now"() - '7 days'::interval));


ALTER VIEW "public"."v_notifications_health" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sync_outbox_health" WITH ("security_invoker"='on') AS
 SELECT NULL::bigint AS "pending_operations",
    NULL::interval AS "max_operation_age"
  WHERE false;


ALTER VIEW "public"."v_sync_outbox_health" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_tv_timeline" WITH ("security_invoker"='on') AS
 SELECT (((("e"."tmdb_show_id" || ':'::"text") || "e"."season_number") || ':'::"text") || "e"."episode_number") AS "id",
    "s"."user_id",
    "e"."tmdb_show_id",
    "sh"."name" AS "show_name",
    "sh"."poster_path" AS "show_poster_path",
    "e"."season_number",
    "e"."episode_number",
    "e"."name" AS "episode_name",
    "e"."air_date",
    "e"."still_path",
    "public"."is_special_episode"("e"."season_number") AS "is_special"
   FROM (("public"."tv_show_state" "s"
     JOIN "public"."tmdb_episodes" "e" ON (("e"."tmdb_show_id" = "s"."tmdb_show_id")))
     LEFT JOIN "public"."tmdb_shows" "sh" ON (("sh"."tmdb_show_id" = "s"."tmdb_show_id")))
  WHERE (("s"."user_status" = 'active'::"text") AND ("e"."air_date" IS NOT NULL) AND ("e"."air_date" >= "public"."user_today"("s"."user_id")) AND ("e"."air_date" <= ("public"."user_today"("s"."user_id") + 30)));


ALTER VIEW "public"."v_tv_timeline" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_tv_timeline" IS 'SPEC v3 §9.2: le uscite dei prossimi 30 giorni per le serie attive. Gli speciali ci sono e sono marcati (§1.3), la scelta se mostrarli e'' della UI.';



CREATE OR REPLACE VIEW "public"."v_tv_tracking" WITH ("security_invoker"='on') AS
 SELECT "s"."user_id",
    "s"."tmdb_show_id",
    "s"."user_status",
    "s"."watched_count",
    "s"."aired_count",
    "s"."total_count",
    "s"."last_watched_at",
    "s"."next_season",
    "s"."next_episode",
    "s"."next_air_date",
    "s"."backlog_since",
    "s"."first_watched_at",
    "s"."completed_at",
    "s"."updated_at",
    "s"."synced_at",
    "public"."tv_tracking_bucket"("s"."user_status", "s"."watched_count", "s"."backlog_since") AS "bucket",
    (("s"."next_air_date" IS NOT NULL) AND ("s"."next_air_date" <= "public"."user_today"("s"."user_id"))) AS "is_next_available",
    "sh"."name" AS "show_name",
    "sh"."poster_path" AS "show_poster_path",
    "sh"."status" AS "show_status",
    "ne"."name" AS "next_episode_name",
    "ne"."still_path" AS "next_still_path",
    "ne"."runtime_minutes" AS "next_runtime_minutes"
   FROM (("public"."tv_show_state" "s"
     LEFT JOIN "public"."tmdb_shows" "sh" ON (("sh"."tmdb_show_id" = "s"."tmdb_show_id")))
     LEFT JOIN "public"."tmdb_episodes" "ne" ON ((("ne"."tmdb_show_id" = "s"."tmdb_show_id") AND ("ne"."season_number" = "s"."next_season") AND ("ne"."episode_number" = "s"."next_episode"))));


ALTER VIEW "public"."v_tv_tracking" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_tv_tracking" IS 'SPEC v3 §9.2: una riga per serie seguita, gia'' pronta per la card — stato derivato dal server (§1.1) piu'' i campi di catalogo, cosi'' il client non deve ricomporre niente.';



CREATE OR REPLACE VIEW "public"."v_user_engagement" WITH ("security_invoker"='on') AS
 SELECT "count"(*) FILTER (WHERE ("updated_at" >= ("now"() - '1 day'::interval))) AS "dau",
    "count"(*) FILTER (WHERE ("updated_at" >= ("now"() - '30 days'::interval))) AS "mau",
    "avg"("total_xp") AS "avg_xp",
    "percentile_disc"((0.5)::double precision) WITHIN GROUP (ORDER BY "current_streak") AS "p50_streak"
   FROM "public"."user_gamification";


ALTER VIEW "public"."v_user_engagement" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."watch_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "media_type" "text" NOT NULL,
    "tmdb_movie_id" integer,
    "tmdb_show_id" integer,
    "season_number" integer,
    "episode_number" integer,
    "watched_at" timestamp with time zone NOT NULL,
    "logged_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "watched_at_precision" "text" DEFAULT 'exact'::"text" NOT NULL,
    "runtime_seconds" integer,
    "is_special" boolean DEFAULT false NOT NULL,
    "rewatch_index" integer DEFAULT 0 NOT NULL,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "external_ref" "jsonb",
    "dedup_key" "text",
    "device_id" "text",
    "deleted_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    CONSTRAINT "watch_events_media_type_check" CHECK (("media_type" = ANY (ARRAY['movie'::"text", 'tv'::"text"]))),
    CONSTRAINT "watch_events_rewatch_index_check" CHECK (("rewatch_index" >= 0)),
    CONSTRAINT "watch_events_shape" CHECK (((("media_type" = 'movie'::"text") AND ("tmdb_movie_id" IS NOT NULL) AND ("tmdb_show_id" IS NULL) AND ("season_number" IS NULL) AND ("episode_number" IS NULL)) OR (("media_type" = 'tv'::"text") AND ("tmdb_show_id" IS NOT NULL) AND ("season_number" IS NOT NULL) AND ("episode_number" IS NOT NULL)))),
    CONSTRAINT "watch_events_source_check" CHECK (("source" = ANY (ARRAY['manual'::"text", 'bulk_season'::"text", 'bulk_show'::"text", 'import_tvtime'::"text", 'import_other'::"text"]))),
    CONSTRAINT "watch_events_watched_at_precision_check" CHECK (("watched_at_precision" = ANY (ARRAY['exact'::"text", 'date_only'::"text", 'inferred'::"text"])))
);


ALTER TABLE "public"."watch_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."xp_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "action_day" "date" DEFAULT CURRENT_DATE NOT NULL,
    "base_xp" integer NOT NULL,
    "multiplier" real DEFAULT 1 NOT NULL,
    "streak_bonus" integer DEFAULT 0 NOT NULL,
    "total_xp" integer NOT NULL,
    "source" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."xp_transactions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_user_id_group_key_key" UNIQUE ("user_id", "group_key");



ALTER TABLE ONLY "public"."activity_comment_likes"
    ADD CONSTRAINT "activity_comment_likes_comment_id_user_id_key" UNIQUE ("comment_id", "user_id");



ALTER TABLE ONLY "public"."activity_comment_likes"
    ADD CONSTRAINT "activity_comment_likes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activity_comments"
    ADD CONSTRAINT "activity_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activity_likes"
    ADD CONSTRAINT "activity_likes_activity_id_user_id_key" UNIQUE ("activity_id", "user_id");



ALTER TABLE ONLY "public"."activity_likes"
    ADD CONSTRAINT "activity_likes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_conversation_history"
    ADD CONSTRAINT "ai_conversation_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_global_usage"
    ADD CONSTRAINT "ai_global_usage_pkey" PRIMARY KEY ("usage_date");



ALTER TABLE ONLY "public"."api_proxy_budget"
    ADD CONSTRAINT "api_proxy_budget_pkey" PRIMARY KEY ("provider", "scope", "window_start");



ALTER TABLE ONLY "public"."api_proxy_cache"
    ADD CONSTRAINT "api_proxy_cache_pkey" PRIMARY KEY ("provider", "cache_key");



ALTER TABLE ONLY "public"."clip_comment_likes"
    ADD CONSTRAINT "clip_comment_likes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clip_comment_likes"
    ADD CONSTRAINT "clip_comment_likes_unique" UNIQUE ("comment_id", "user_id");



ALTER TABLE ONLY "public"."clip_comments"
    ADD CONSTRAINT "clip_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clip_reactions"
    ADD CONSTRAINT "clip_reactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clip_reactions"
    ADD CONSTRAINT "clip_reactions_user_clip_unique" UNIQUE ("user_id", "clip_id", "reaction_type");



ALTER TABLE ONLY "public"."clips"
    ADD CONSTRAINT "clips_clip_id_key" UNIQUE ("clip_id");



ALTER TABLE ONLY "public"."clips"
    ADD CONSTRAINT "clips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_reporter_id_content_type_content_id_key" UNIQUE ("reporter_id", "content_type", "content_id");



ALTER TABLE ONLY "public"."device_info"
    ADD CONSTRAINT "device_info_pkey" PRIMARY KEY ("device_id");



ALTER TABLE ONLY "public"."discovery_cache"
    ADD CONSTRAINT "discovery_cache_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."discovery_warm_feeds"
    ADD CONSTRAINT "discovery_warm_feeds_pkey" PRIMARY KEY ("region", "carousel_type");



ALTER TABLE ONLY "public"."email_send_log"
    ADD CONSTRAINT "email_send_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."global_discovery_filters"
    ADD CONSTRAINT "global_discovery_filters_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."health_check"
    ADD CONSTRAINT "health_check_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."import_jobs"
    ADD CONSTRAINT "import_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."import_staging"
    ADD CONSTRAINT "import_staging_pkey" PRIMARY KEY ("job_id", "row_index");



ALTER TABLE ONLY "public"."list_follows"
    ADD CONSTRAINT "list_follows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."list_items"
    ADD CONSTRAINT "list_items_list_id_media_id_media_type_key" UNIQUE ("list_id", "media_id", "media_type");



ALTER TABLE ONLY "public"."list_items"
    ADD CONSTRAINT "list_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."list_reports"
    ADD CONSTRAINT "list_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lists"
    ADD CONSTRAINT "lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."media_availability"
    ADD CONSTRAINT "media_availability_media_id_media_type_provider_id_country__key" UNIQUE ("media_id", "media_type", "provider_id", "country_code", "availability_type");



ALTER TABLE ONLY "public"."media_availability"
    ADD CONSTRAINT "media_availability_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."media_details_cache"
    ADD CONSTRAINT "media_details_cache_pkey" PRIMARY KEY ("tmdb_id");



ALTER TABLE ONLY "public"."movie_reaction_counts"
    ADD CONSTRAINT "movie_reaction_counts_pkey" PRIMARY KEY ("media_id", "media_type");



ALTER TABLE ONLY "public"."movie_reactions"
    ADD CONSTRAINT "movie_reactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."movie_reactions"
    ADD CONSTRAINT "movie_reactions_user_id_media_id_media_type_key" UNIQUE ("user_id", "media_id", "media_type");



ALTER TABLE ONLY "public"."notification_delivery_log"
    ADD CONSTRAINT "notification_delivery_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."personalized_discovery"
    ADD CONSTRAINT "personalized_discovery_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."personalized_discovery"
    ADD CONSTRAINT "personalized_discovery_user_id_carousel_type_media_id_key" UNIQUE ("user_id", "carousel_type", "media_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."release_alerts"
    ADD CONSTRAINT "release_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."release_alerts"
    ADD CONSTRAINT "release_alerts_user_id_media_id_media_type_key" UNIQUE ("user_id", "media_id", "media_type");



ALTER TABLE ONLY "public"."revenuecat_webhook_logs"
    ADD CONSTRAINT "revenuecat_webhook_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sync_rejected_mutations"
    ADD CONSTRAINT "sync_rejected_mutations_pkey" PRIMARY KEY ("user_id", "table_name", "reason", "day");



ALTER TABLE ONLY "public"."tmdb_episodes"
    ADD CONSTRAINT "tmdb_episodes_pkey" PRIMARY KEY ("tmdb_show_id", "season_number", "episode_number");



ALTER TABLE ONLY "public"."tmdb_shows"
    ADD CONSTRAINT "tmdb_shows_pkey" PRIMARY KEY ("tmdb_show_id");



ALTER TABLE ONLY "public"."trailers_cache"
    ADD CONSTRAINT "trailers_cache_pkey" PRIMARY KEY ("tmdb_id", "media_type", "youtube_id");



ALTER TABLE ONLY "public"."tv_show_state"
    ADD CONSTRAINT "tv_show_state_pkey" PRIMARY KEY ("user_id", "tmdb_show_id");



ALTER TABLE ONLY "public"."tvdb_tmdb_map"
    ADD CONSTRAINT "tvdb_tmdb_map_pkey" PRIMARY KEY ("tvdb_id", "entity_type");



ALTER TABLE ONLY "public"."unified_user_preferences"
    ADD CONSTRAINT "unified_user_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."unified_user_preferences"
    ADD CONSTRAINT "unified_user_preferences_user_id_preference_category_prefer_key" UNIQUE ("user_id", "preference_category", "preference_id");



ALTER TABLE ONLY "public"."user_ai_token_usage"
    ADD CONSTRAINT "user_ai_token_usage_pkey" PRIMARY KEY ("user_id", "usage_date");



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_user_id_badge_id_key" UNIQUE ("user_id", "badge_id");



ALTER TABLE ONLY "public"."user_blocks"
    ADD CONSTRAINT "user_blocks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_clip_history"
    ADD CONSTRAINT "user_clip_history_device_id_clip_id_key" UNIQUE ("device_id", "clip_id");



ALTER TABLE ONLY "public"."user_clip_history"
    ADD CONSTRAINT "user_clip_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_clip_signals"
    ADD CONSTRAINT "user_clip_signals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_daily_challenges"
    ADD CONSTRAINT "user_daily_challenges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_daily_challenges"
    ADD CONSTRAINT "user_daily_challenges_user_id_challenge_date_challenge_type_key" UNIQUE ("user_id", "challenge_date", "challenge_type");



ALTER TABLE ONLY "public"."user_daily_quota"
    ADD CONSTRAINT "user_daily_quota_device_id_key" UNIQUE ("device_id");



ALTER TABLE ONLY "public"."user_daily_quota"
    ADD CONSTRAINT "user_daily_quota_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_daily_quota"
    ADD CONSTRAINT "user_daily_quota_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_fcm_token_key" UNIQUE ("fcm_token");



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_user_id_fcm_token_key" UNIQUE ("user_id", "fcm_token");



ALTER TABLE ONLY "public"."user_discovery_interactions"
    ADD CONSTRAINT "user_discovery_interactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_entitlements"
    ADD CONSTRAINT "user_entitlements_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_pkey" PRIMARY KEY ("user_id", "media_type", "slot");



ALTER TABLE ONLY "public"."user_follows"
    ADD CONSTRAINT "user_follows_pkey" PRIMARY KEY ("follower_id", "followee_id");



ALTER TABLE ONLY "public"."user_gamification"
    ADD CONSTRAINT "user_gamification_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_preferences"
    ADD CONSTRAINT "user_preferences_device_id_preference_type_preference_id_key" UNIQUE ("device_id", "preference_type", "preference_id");



ALTER TABLE ONLY "public"."user_preferences"
    ADD CONSTRAINT "user_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_reviews"
    ADD CONSTRAINT "user_reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_search_history"
    ADD CONSTRAINT "user_search_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."username_reserved"
    ADD CONSTRAINT "username_reserved_pkey" PRIMARY KEY ("name");



ALTER TABLE ONLY "public"."watch_events"
    ADD CONSTRAINT "watch_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."xp_transactions"
    ADD CONSTRAINT "xp_transactions_pkey" PRIMARY KEY ("id");



CREATE INDEX "activities_global_time" ON "public"."activities" USING "btree" ("occurred_at" DESC) WHERE ("deleted_at" IS NULL);



CREATE INDEX "activities_user_time" ON "public"."activities" USING "btree" ("user_id", "occurred_at" DESC) WHERE ("deleted_at" IS NULL);



CREATE INDEX "activity_comment_likes_by_comment" ON "public"."activity_comment_likes" USING "btree" ("comment_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "activity_comments_by_activity" ON "public"."activity_comments" USING "btree" ("activity_id", "created_at") WHERE ("deleted_at" IS NULL);



CREATE INDEX "activity_likes_by_activity" ON "public"."activity_likes" USING "btree" ("activity_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "clip_comment_likes_user_idx" ON "public"."clip_comment_likes" USING "btree" ("user_id");



CREATE INDEX "clip_comments_clip_idx" ON "public"."clip_comments" USING "btree" ("clip_id", "deleted_at");



CREATE INDEX "clip_comments_parent_idx" ON "public"."clip_comments" USING "btree" ("parent_comment_id");



CREATE INDEX "clip_comments_user_idx" ON "public"."clip_comments" USING "btree" ("user_id");



CREATE INDEX "clip_reactions_user_idx" ON "public"."clip_reactions" USING "btree" ("user_id");



CREATE INDEX "clips_updated_at_idx" ON "public"."clips" USING "btree" ("updated_at");



CREATE INDEX "content_reports_by_content" ON "public"."content_reports" USING "btree" ("content_type", "content_id");



CREATE INDEX "email_send_log_sent_at_idx" ON "public"."email_send_log" USING "btree" ("sent_at" DESC);



CREATE INDEX "email_send_log_user_type_idx" ON "public"."email_send_log" USING "btree" ("user_id", "email_type", "sent_at" DESC);



CREATE INDEX "idx_ai_history_user" ON "public"."ai_conversation_history" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_api_proxy_budget_window" ON "public"."api_proxy_budget" USING "btree" ("window_start");



CREATE INDEX "idx_api_proxy_cache_expires" ON "public"."api_proxy_cache" USING "btree" ("expires_at");



CREATE INDEX "idx_clips_active" ON "public"."clips" USING "btree" ("is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_clips_country" ON "public"."clips" USING "btree" ("country_code");



CREATE INDEX "idx_clips_country_language" ON "public"."clips" USING "btree" ("country_code", "language_code");



CREATE INDEX "idx_clips_deleted" ON "public"."clips" USING "btree" ("deleted_at");



CREATE INDEX "idx_clips_media_type" ON "public"."clips" USING "btree" ("media_type");



CREATE INDEX "idx_device_user" ON "public"."device_info" USING "btree" ("user_id");



CREATE INDEX "idx_discovery_cache_expires" ON "public"."discovery_cache" USING "btree" ("expires_at");



CREATE INDEX "idx_discovery_cache_type" ON "public"."discovery_cache" USING "btree" ("content_type", "expires_at");



CREATE INDEX "idx_discovery_deleted" ON "public"."discovery_cache" USING "btree" ("deleted_at");



CREATE INDEX "idx_discovery_interactions_user" ON "public"."user_discovery_interactions" USING "btree" ("user_id", "interacted_at" DESC);



CREATE INDEX "idx_import_jobs_user_open" ON "public"."import_jobs" USING "btree" ("user_id", "created_at" DESC) WHERE ("status" = ANY (ARRAY['running'::"text", 'paused'::"text"]));



CREATE INDEX "idx_import_staging_job_status" ON "public"."import_staging" USING "btree" ("job_id", "status", "row_index");



CREATE INDEX "idx_list_follows_list" ON "public"."list_follows" USING "btree" ("list_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_list_follows_user" ON "public"."list_follows" USING "btree" ("user_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_list_items_deleted" ON "public"."list_items" USING "btree" ("deleted_at");



CREATE INDEX "idx_list_items_list_id" ON "public"."list_items" USING "btree" ("list_id");



CREATE INDEX "idx_list_items_media" ON "public"."list_items" USING "btree" ("media_id", "media_type");



CREATE INDEX "idx_list_items_user_id" ON "public"."list_items" USING "btree" ("user_id");



CREATE INDEX "idx_list_reports_list" ON "public"."list_reports" USING "btree" ("list_id");



CREATE INDEX "idx_lists_created_at" ON "public"."lists" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_lists_deleted" ON "public"."lists" USING "btree" ("deleted_at");



CREATE UNIQUE INDEX "idx_lists_one_active_default_per_user_type" ON "public"."lists" USING "btree" ("user_id", "type") WHERE (("deleted_at" IS NULL) AND ("type" = ANY (ARRAY['watchlist'::"text", 'seen'::"text", 'liked'::"text", 'disliked'::"text"])));



CREATE INDEX "idx_lists_public" ON "public"."lists" USING "btree" ("updated_at" DESC) WHERE ("is_public" AND ("deleted_at" IS NULL));



CREATE INDEX "idx_lists_user_id" ON "public"."lists" USING "btree" ("user_id");



CREATE INDEX "idx_media_availability_country" ON "public"."media_availability" USING "btree" ("country_code");



CREATE INDEX "idx_media_availability_media" ON "public"."media_availability" USING "btree" ("media_id", "media_type");



CREATE INDEX "idx_movie_reactions_media" ON "public"."movie_reactions" USING "btree" ("media_id", "media_type");



CREATE INDEX "idx_movie_reactions_user" ON "public"."movie_reactions" USING "btree" ("user_id");



CREATE INDEX "idx_notifications_user" ON "public"."notifications" USING "btree" ("user_id", "is_sent");



CREATE INDEX "idx_personalized_discovery" ON "public"."personalized_discovery" USING "btree" ("user_id", "carousel_type", "position");



CREATE INDEX "idx_preferences_user" ON "public"."user_preferences" USING "btree" ("user_id", "preference_type") WHERE ("user_id" IS NOT NULL);



CREATE INDEX "idx_quota_user" ON "public"."user_daily_quota" USING "btree" ("user_id") WHERE ("user_id" IS NOT NULL);



CREATE INDEX "idx_release_alerts_media" ON "public"."release_alerts" USING "btree" ("media_id", "media_type", "is_active");



CREATE INDEX "idx_release_alerts_user" ON "public"."release_alerts" USING "btree" ("user_id", "is_active");



CREATE INDEX "idx_search_relevance" ON "public"."user_search_history" USING "btree" ("user_id", "relevance_score" DESC);



CREATE INDEX "idx_tmdb_episodes_air_date" ON "public"."tmdb_episodes" USING "btree" ("air_date") WHERE ("air_date" IS NOT NULL);



CREATE INDEX "idx_tmdb_episodes_show_season" ON "public"."tmdb_episodes" USING "btree" ("tmdb_show_id", "season_number");



CREATE INDEX "idx_tmdb_shows_next_refresh" ON "public"."tmdb_shows" USING "btree" ("next_refresh_at");



CREATE INDEX "idx_tv_show_state_backlog" ON "public"."tv_show_state" USING "btree" ("user_id", "backlog_since" DESC);



CREATE INDEX "idx_tv_show_state_next_air" ON "public"."tv_show_state" USING "btree" ("next_air_date") WHERE ("user_status" = 'active'::"text");



CREATE INDEX "idx_tvdb_tmdb_map_retry" ON "public"."tvdb_tmdb_map" USING "btree" ("resolution", "resolved_at");



CREATE INDEX "idx_unified_prefs_updated" ON "public"."unified_user_preferences" USING "btree" ("user_id", "updated_at" DESC);



CREATE INDEX "idx_user_ai_token_usage_user_id" ON "public"."user_ai_token_usage" USING "btree" ("user_id");



CREATE INDEX "idx_user_blocks_user" ON "public"."user_blocks" USING "btree" ("user_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_user_devices_user_id" ON "public"."user_devices" USING "btree" ("user_id");



CREATE INDEX "idx_user_history_clip" ON "public"."user_clip_history" USING "btree" ("clip_id");



CREATE INDEX "idx_user_history_device" ON "public"."user_clip_history" USING "btree" ("device_id", "watched_at" DESC);



CREATE INDEX "idx_user_history_user" ON "public"."user_clip_history" USING "btree" ("user_id", "watched_at" DESC) WHERE ("user_id" IS NOT NULL);



CREATE INDEX "idx_webhook_logs_received" ON "public"."revenuecat_webhook_logs" USING "btree" ("received_at" DESC);



CREATE INDEX "idx_xp_user_created" ON "public"."xp_transactions" USING "btree" ("user_id", "created_at" DESC);



CREATE UNIQUE INDEX "import_jobs_one_open_per_user" ON "public"."import_jobs" USING "btree" ("user_id") WHERE ("status" = ANY (ARRAY['running'::"text", 'paused'::"text"]));



CREATE INDEX "notification_delivery_log_user_time" ON "public"."notification_delivery_log" USING "btree" ("user_id", "delivered_at" DESC);



CREATE INDEX "profiles_display_name_trgm" ON "public"."profiles" USING "gin" ("display_name" "extensions"."gin_trgm_ops");



CREATE INDEX "profiles_username_trgm" ON "public"."profiles" USING "gin" ("username" "extensions"."gin_trgm_ops");



CREATE UNIQUE INDEX "profiles_username_unique" ON "public"."profiles" USING "btree" ("username") WHERE (("username" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "release_alerts_active_idx" ON "public"."release_alerts" USING "btree" ("media_type", "media_id") WHERE ("is_active" AND ("deleted_at" IS NULL));



CREATE UNIQUE INDEX "uq_list_follows_user_list" ON "public"."list_follows" USING "btree" ("user_id", "list_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "uq_list_reports_user_list" ON "public"."list_reports" USING "btree" ("user_id", "list_id");



CREATE UNIQUE INDEX "uq_user_blocks_pair" ON "public"."user_blocks" USING "btree" ("user_id", "blocked_user_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "user_clip_signals_user_id_idx" ON "public"."user_clip_signals" USING "btree" ("user_id");



CREATE INDEX "user_follows_followee" ON "public"."user_follows" USING "btree" ("followee_id") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "user_ratings_natural_key" ON "public"."user_ratings" USING "btree" ("user_id", "media_type", "tmdb_id", COALESCE("season_number", '-1'::integer), COALESCE("episode_number", '-1'::integer)) WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "user_reviews_one_per_title" ON "public"."user_reviews" USING "btree" ("user_id", "media_type", "tmdb_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "watch_events_by_episode" ON "public"."watch_events" USING "btree" ("user_id", "tmdb_show_id", "season_number", "episode_number") WHERE ("deleted_at" IS NULL);



CREATE INDEX "watch_events_by_watched_at" ON "public"."watch_events" USING "btree" ("user_id", "watched_at" DESC) WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "watch_events_dedup" ON "public"."watch_events" USING "btree" ("user_id", "dedup_key") WHERE (("dedup_key" IS NOT NULL) AND ("deleted_at" IS NULL));



CREATE UNIQUE INDEX "xp_unique_daily" ON "public"."xp_transactions" USING "btree" ("user_id", "action_type", "action_day") WHERE ("action_type" = ANY (ARRAY['daily_open'::"text", 'first_action_of_day'::"text", 'streak_day'::"text"]));



CREATE OR REPLACE TRIGGER "activity_comments_notify" AFTER INSERT ON "public"."activity_comments" FOR EACH ROW EXECUTE FUNCTION "public"."tg_activity_comments_notify"();



CREATE OR REPLACE TRIGGER "activity_likes_notify" AFTER INSERT OR UPDATE ON "public"."activity_likes" FOR EACH ROW EXECUTE FUNCTION "public"."tg_activity_likes_notify"();



CREATE OR REPLACE TRIGGER "clip_comment_likes_dec" AFTER DELETE ON "public"."clip_comment_likes" FOR EACH ROW EXECUTE FUNCTION "public"."clip_comment_like_count_dec"();



CREATE OR REPLACE TRIGGER "clip_comment_likes_inc" AFTER INSERT ON "public"."clip_comment_likes" FOR EACH ROW EXECUTE FUNCTION "public"."clip_comment_like_count_inc"();



CREATE OR REPLACE TRIGGER "clip_comments_clip_dec" AFTER DELETE ON "public"."clip_comments" FOR EACH ROW EXECUTE FUNCTION "public"."clip_comments_clip_count_dec"();



CREATE OR REPLACE TRIGGER "clip_comments_clip_inc" AFTER INSERT ON "public"."clip_comments" FOR EACH ROW EXECUTE FUNCTION "public"."clip_comments_clip_count_inc"();



CREATE OR REPLACE TRIGGER "clip_comments_reply_dec" AFTER DELETE ON "public"."clip_comments" FOR EACH ROW EXECUTE FUNCTION "public"."clip_comments_reply_count_dec"();



CREATE OR REPLACE TRIGGER "clip_comments_reply_inc" AFTER INSERT ON "public"."clip_comments" FOR EACH ROW EXECUTE FUNCTION "public"."clip_comments_reply_count_inc"();



CREATE OR REPLACE TRIGGER "clip_comments_set_updated_at" BEFORE UPDATE ON "public"."clip_comments" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "clip_reactions_set_updated_at" BEFORE UPDATE ON "public"."clip_reactions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "list_items_enroll_alert" AFTER INSERT OR UPDATE ON "public"."list_items" FOR EACH ROW EXECUTE FUNCTION "public"."tg_list_items_enroll_alert"();



CREATE OR REPLACE TRIGGER "list_items_retire_alert" AFTER DELETE OR UPDATE ON "public"."list_items" FOR EACH ROW EXECUTE FUNCTION "public"."tg_list_items_retire_alert"();



CREATE OR REPLACE TRIGGER "lists_activities" AFTER INSERT OR UPDATE ON "public"."lists" FOR EACH ROW EXECUTE FUNCTION "public"."tg_lists_activities"();



CREATE OR REPLACE TRIGGER "profiles_username_changed" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."tg_profiles_username_changed"();



CREATE OR REPLACE TRIGGER "trg_clips_updated_at" BEFORE UPDATE ON "public"."clips" FOR EACH ROW EXECUTE FUNCTION "public"."set_clips_updated_at"();



CREATE OR REPLACE TRIGGER "trg_enforce_custom_list_limit" BEFORE INSERT OR UPDATE ON "public"."lists" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_custom_list_limit"();



CREATE OR REPLACE TRIGGER "trg_enforce_is_pro" BEFORE INSERT OR UPDATE ON "public"."user_daily_quota" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_is_pro_server_authoritative"();



CREATE OR REPLACE TRIGGER "trg_import_jobs_touch" BEFORE UPDATE ON "public"."import_jobs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_import_job"();



CREATE OR REPLACE TRIGGER "trg_movie_reactions_counts" AFTER INSERT OR DELETE OR UPDATE ON "public"."movie_reactions" FOR EACH ROW EXECUTE FUNCTION "public"."refresh_movie_reaction_counts"();



CREATE OR REPLACE TRIGGER "tv_show_state_activities_ins" AFTER INSERT ON "public"."tv_show_state" FOR EACH ROW WHEN (("new"."completed_at" IS NOT NULL)) EXECUTE FUNCTION "public"."tg_tv_show_state_activities"();



CREATE OR REPLACE TRIGGER "tv_show_state_activities_upd" AFTER UPDATE ON "public"."tv_show_state" FOR EACH ROW WHEN (("old"."completed_at" IS DISTINCT FROM "new"."completed_at")) EXECUTE FUNCTION "public"."tg_tv_show_state_activities"();



CREATE OR REPLACE TRIGGER "update_filters_updated_at" BEFORE UPDATE ON "public"."global_discovery_filters" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_unified_prefs_updated_at" BEFORE UPDATE ON "public"."unified_user_preferences" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "user_blocks_prune_follows" AFTER INSERT OR UPDATE ON "public"."user_blocks" FOR EACH ROW EXECUTE FUNCTION "public"."tg_user_blocks_prune_follows"();



CREATE OR REPLACE TRIGGER "user_devices_set_updated_at" BEFORE UPDATE ON "public"."user_devices" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "user_follows_blocked" BEFORE INSERT OR UPDATE ON "public"."user_follows" FOR EACH ROW EXECUTE FUNCTION "public"."tg_user_follows_blocked"();



CREATE OR REPLACE TRIGGER "user_follows_notify" AFTER INSERT OR UPDATE ON "public"."user_follows" FOR EACH ROW EXECUTE FUNCTION "public"."tg_user_follows_notify"();



CREATE OR REPLACE TRIGGER "user_ratings_activities" AFTER INSERT OR UPDATE ON "public"."user_ratings" FOR EACH ROW EXECUTE FUNCTION "public"."tg_user_ratings_activities"();



CREATE OR REPLACE TRIGGER "user_reviews_activities" AFTER INSERT OR UPDATE ON "public"."user_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."tg_user_reviews_activities"();



CREATE OR REPLACE TRIGGER "watch_events_activities" AFTER INSERT OR UPDATE ON "public"."watch_events" FOR EACH ROW EXECUTE FUNCTION "public"."tg_watch_events_activities"();



CREATE OR REPLACE TRIGGER "watch_events_recompute_delete" AFTER UPDATE ON "public"."watch_events" REFERENCING OLD TABLE AS "previous_rows" NEW TABLE AS "changed_rows" FOR EACH STATEMENT EXECUTE FUNCTION "public"."tg_watch_events_recompute"();



CREATE OR REPLACE TRIGGER "watch_events_recompute_insert" AFTER INSERT ON "public"."watch_events" REFERENCING NEW TABLE AS "changed_rows" FOR EACH STATEMENT EXECUTE FUNCTION "public"."tg_watch_events_recompute"();



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."user_reviews"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_comment_likes"
    ADD CONSTRAINT "activity_comment_likes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."activity_comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_comment_likes"
    ADD CONSTRAINT "activity_comment_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_comments"
    ADD CONSTRAINT "activity_comments_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_comments"
    ADD CONSTRAINT "activity_comments_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."activity_comments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activity_comments"
    ADD CONSTRAINT "activity_comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_likes"
    ADD CONSTRAINT "activity_likes_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity_likes"
    ADD CONSTRAINT "activity_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ai_conversation_history"
    ADD CONSTRAINT "ai_conversation_history_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clip_comment_likes"
    ADD CONSTRAINT "clip_comment_likes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."clip_comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clip_comment_likes"
    ADD CONSTRAINT "clip_comment_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clip_comments"
    ADD CONSTRAINT "clip_comments_parent_comment_id_fkey" FOREIGN KEY ("parent_comment_id") REFERENCES "public"."clip_comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clip_comments"
    ADD CONSTRAINT "clip_comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clip_reactions"
    ADD CONSTRAINT "clip_reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_reporter_id_fkey" FOREIGN KEY ("reporter_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."device_info"
    ADD CONSTRAINT "device_info_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_send_log"
    ADD CONSTRAINT "email_send_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_ai_token_usage"
    ADD CONSTRAINT "fk_user_id" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."global_discovery_filters"
    ADD CONSTRAINT "global_discovery_filters_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."import_jobs"
    ADD CONSTRAINT "import_jobs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."import_staging"
    ADD CONSTRAINT "import_staging_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."import_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_follows"
    ADD CONSTRAINT "list_follows_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_follows"
    ADD CONSTRAINT "list_follows_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_items"
    ADD CONSTRAINT "list_items_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_items"
    ADD CONSTRAINT "list_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_reports"
    ADD CONSTRAINT "list_reports_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_reports"
    ADD CONSTRAINT "list_reports_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lists"
    ADD CONSTRAINT "lists_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."movie_reactions"
    ADD CONSTRAINT "movie_reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_delivery_log"
    ADD CONSTRAINT "notification_delivery_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."personalized_discovery"
    ADD CONSTRAINT "personalized_discovery_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."release_alerts"
    ADD CONSTRAINT "release_alerts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_rejected_mutations"
    ADD CONSTRAINT "sync_rejected_mutations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tmdb_episodes"
    ADD CONSTRAINT "tmdb_episodes_tmdb_show_id_fkey" FOREIGN KEY ("tmdb_show_id") REFERENCES "public"."tmdb_shows"("tmdb_show_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tv_show_state"
    ADD CONSTRAINT "tv_show_state_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."unified_user_preferences"
    ADD CONSTRAINT "unified_user_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_blocks"
    ADD CONSTRAINT "user_blocks_blocked_user_id_fkey" FOREIGN KEY ("blocked_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_blocks"
    ADD CONSTRAINT "user_blocks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_clip_history"
    ADD CONSTRAINT "user_clip_history_clip_id_fkey" FOREIGN KEY ("clip_id") REFERENCES "public"."clips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_clip_signals"
    ADD CONSTRAINT "user_clip_signals_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_daily_challenges"
    ADD CONSTRAINT "user_daily_challenges_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_discovery_interactions"
    ADD CONSTRAINT "user_discovery_interactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_entitlements"
    ADD CONSTRAINT "user_entitlements_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_follows"
    ADD CONSTRAINT "user_follows_followee_id_fkey" FOREIGN KEY ("followee_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_follows"
    ADD CONSTRAINT "user_follows_follower_id_fkey" FOREIGN KEY ("follower_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_gamification"
    ADD CONSTRAINT "user_gamification_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_ratings"
    ADD CONSTRAINT "user_ratings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_reviews"
    ADD CONSTRAINT "user_reviews_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_search_history"
    ADD CONSTRAINT "user_search_history_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."watch_events"
    ADD CONSTRAINT "watch_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."xp_transactions"
    ADD CONSTRAINT "xp_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Allow public read access to clips" ON "public"."clips" FOR SELECT USING (true);



CREATE POLICY "Allow public read access to discovery cache" ON "public"."discovery_cache" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow public read access to health check" ON "public"."health_check" FOR SELECT USING (true);



CREATE POLICY "Allow public read access to media availability" ON "public"."media_availability" FOR SELECT USING (true);



CREATE POLICY "Allow public read access to media details cache" ON "public"."media_details_cache" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow public read access to trailers cache" ON "public"."trailers_cache" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow service role full access to discovery cache" ON "public"."discovery_cache" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service role full access to media details cache" ON "public"."media_details_cache" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service role full access to trailers cache" ON "public"."trailers_cache" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role to manage media availability" ON "public"."media_availability" TO "service_role" USING ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text")) WITH CHECK ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text"));



CREATE POLICY "Allow service_role to update health check" ON "public"."health_check" FOR UPDATE USING ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text")) WITH CHECK ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text"));



CREATE POLICY "Anonymous device rows are readable only" ON "public"."user_daily_quota" FOR SELECT TO "anon" USING ((("user_id" IS NULL) AND ("device_id" IS NOT NULL)));



CREATE POLICY "Owners manage their own quota row" ON "public"."user_daily_quota" TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Owners read their own entitlement" ON "public"."user_entitlements" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Service role can manage user devices" ON "public"."user_devices" TO "service_role" USING ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text")) WITH CHECK ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text"));



CREATE POLICY "Service role has full access to webhook logs" ON "public"."revenuecat_webhook_logs" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Users can add items to own lists" ON "public"."list_items" FOR INSERT TO "authenticated" WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "user_id") AND (EXISTS ( SELECT 1
   FROM "public"."lists" "l"
  WHERE (("l"."id" = "list_items"."list_id") AND ("l"."user_id" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Users can create own lists" ON "public"."lists" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete items from own lists" ON "public"."list_items" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete own discovery" ON "public"."personalized_discovery" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete own filters" ON "public"."global_discovery_filters" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete own lists" ON "public"."lists" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete own search history" ON "public"."user_search_history" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete their own device tokens" ON "public"."user_devices" FOR DELETE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete their own notifications" ON "public"."notifications" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own conversations" ON "public"."ai_conversation_history" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own devices" ON "public"."device_info" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own discovery" ON "public"."personalized_discovery" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own filters" ON "public"."global_discovery_filters" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own interactions" ON "public"."user_discovery_interactions" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own preferences" ON "public"."unified_user_preferences" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert own search history" ON "public"."user_search_history" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert their own device tokens" ON "public"."user_devices" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can manage their own clip history" ON "public"."user_clip_history" USING (((( SELECT "auth"."uid"() AS "uid") = "user_id") OR ("device_id" IS NOT NULL)));



CREATE POLICY "Users can manage their own preferences" ON "public"."user_preferences" USING (((( SELECT "auth"."uid"() AS "uid") = "user_id") OR ("device_id" IS NOT NULL)));



CREATE POLICY "Users can manage their own release alerts" ON "public"."release_alerts" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read their own AI token usage" ON "public"."user_ai_token_usage" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read their own notifications" ON "public"."notifications" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own devices" ON "public"."device_info" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own discovery" ON "public"."personalized_discovery" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own filters" ON "public"."global_discovery_filters" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own lists" ON "public"."lists" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own preferences" ON "public"."unified_user_preferences" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own search history" ON "public"."user_search_history" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own AI token usage" ON "public"."user_ai_token_usage" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own device tokens" ON "public"."user_devices" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own notifications" ON "public"."notifications" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own conversations" ON "public"."ai_conversation_history" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own devices" ON "public"."device_info" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own discovery" ON "public"."personalized_discovery" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own filters" ON "public"."global_discovery_filters" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own interactions" ON "public"."user_discovery_interactions" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own list items" ON "public"."list_items" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own lists" ON "public"."lists" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own preferences" ON "public"."unified_user_preferences" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view own search history" ON "public"."user_search_history" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view their own webhook logs" ON "public"."revenuecat_webhook_logs" FOR SELECT TO "authenticated" USING (("app_user_id" = (( SELECT "auth"."uid"() AS "uid"))::"text"));



ALTER TABLE "public"."activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activities_select_own" ON "public"."activities" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."activity_comment_likes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activity_comment_likes_select_own" ON "public"."activity_comment_likes" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."activity_comments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activity_comments_select_own" ON "public"."activity_comments" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."activity_likes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activity_likes_select_own" ON "public"."activity_likes" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."ai_conversation_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_global_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."api_proxy_budget" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."api_proxy_cache" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "blocks_delete_own" ON "public"."user_blocks" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "blocks_insert_own" ON "public"."user_blocks" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "blocks_select_own" ON "public"."user_blocks" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "blocks_update_own" ON "public"."user_blocks" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."clip_comment_likes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clip_comment_likes_delete" ON "public"."clip_comment_likes" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "clip_comment_likes_insert" ON "public"."clip_comment_likes" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "clip_comment_likes_select" ON "public"."clip_comment_likes" FOR SELECT USING (true);



ALTER TABLE "public"."clip_comments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clip_comments_delete" ON "public"."clip_comments" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "clip_comments_insert" ON "public"."clip_comments" FOR INSERT WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "user_id") AND ("deleted_at" IS NULL)));



CREATE POLICY "clip_comments_select" ON "public"."clip_comments" FOR SELECT USING (true);



CREATE POLICY "clip_comments_update" ON "public"."clip_comments" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."clip_reactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clip_reactions_delete" ON "public"."clip_reactions" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "clip_reactions_insert" ON "public"."clip_reactions" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "clip_reactions_select" ON "public"."clip_reactions" FOR SELECT USING (true);



ALTER TABLE "public"."clips" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."content_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."device_info" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."discovery_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."discovery_warm_feeds" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "discovery_warm_feeds_public_read" ON "public"."discovery_warm_feeds" FOR SELECT USING (("expires_at" > "now"()));



ALTER TABLE "public"."email_send_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "favorites_insert_own" ON "public"."user_favorites" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "favorites_select_own" ON "public"."user_favorites" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "favorites_update_own" ON "public"."user_favorites" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "follows_delete_own" ON "public"."list_follows" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "follows_insert_own" ON "public"."list_follows" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "follows_insert_own" ON "public"."user_follows" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "follower_id"));



CREATE POLICY "follows_select_own" ON "public"."list_follows" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "follows_select_own" ON "public"."user_follows" FOR SELECT USING (((( SELECT "auth"."uid"() AS "uid") = "follower_id") OR (( SELECT "auth"."uid"() AS "uid") = "followee_id")));



CREATE POLICY "follows_update_own" ON "public"."list_follows" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "follows_update_own" ON "public"."user_follows" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "follower_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "follower_id"));



ALTER TABLE "public"."global_discovery_filters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."health_check" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."import_jobs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "import_jobs_select_own" ON "public"."import_jobs" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."import_staging" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "import_staging_select_own" ON "public"."import_staging" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."import_jobs" "j"
  WHERE (("j"."id" = "import_staging"."job_id") AND ("j"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



ALTER TABLE "public"."list_follows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."list_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."list_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."media_availability" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."media_details_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."movie_reaction_counts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "movie_reaction_counts_select" ON "public"."movie_reaction_counts" FOR SELECT USING (true);



ALTER TABLE "public"."movie_reactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "movie_reactions_delete" ON "public"."movie_reactions" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "movie_reactions_insert" ON "public"."movie_reactions" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "movie_reactions_select" ON "public"."movie_reactions" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "movie_reactions_update" ON "public"."movie_reactions" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."notification_delivery_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."personalized_discovery" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_delete_own" ON "public"."profiles" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "profiles_insert_own" ON "public"."profiles" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "profiles_select_own" ON "public"."profiles" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "ratings_insert_own" ON "public"."user_ratings" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "ratings_select_own" ON "public"."user_ratings" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "ratings_update_own" ON "public"."user_ratings" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."release_alerts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reports_insert_own" ON "public"."list_reports" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "reports_select_own" ON "public"."list_reports" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."revenuecat_webhook_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reviews_insert_own" ON "public"."user_reviews" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "reviews_select_own" ON "public"."user_reviews" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "reviews_update_own" ON "public"."user_reviews" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."sync_rejected_mutations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tmdb_episodes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tmdb_episodes_select" ON "public"."tmdb_episodes" FOR SELECT USING (true);



ALTER TABLE "public"."tmdb_shows" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tmdb_shows_select" ON "public"."tmdb_shows" FOR SELECT USING (true);



ALTER TABLE "public"."trailers_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tv_show_state" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tv_show_state_insert" ON "public"."tv_show_state" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "tv_show_state_select" ON "public"."tv_show_state" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "tv_show_state_update" ON "public"."tv_show_state" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."tvdb_tmdb_map" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tvdb_tmdb_map_select" ON "public"."tvdb_tmdb_map" FOR SELECT USING (true);



ALTER TABLE "public"."unified_user_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_ai_token_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_badges" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_badges_insert_own" ON "public"."user_badges" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_badges_select_own" ON "public"."user_badges" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_badges_update_own" ON "public"."user_badges" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."user_blocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_clip_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_clip_signals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_clip_signals_delete" ON "public"."user_clip_signals" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_clip_signals_insert" ON "public"."user_clip_signals" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_clip_signals_select" ON "public"."user_clip_signals" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_clip_signals_update" ON "public"."user_clip_signals" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."user_daily_challenges" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_daily_challenges_insert_own" ON "public"."user_daily_challenges" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_daily_challenges_select_own" ON "public"."user_daily_challenges" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_daily_challenges_update_own" ON "public"."user_daily_challenges" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."user_daily_quota" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_discovery_interactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_entitlements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_follows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_gamification" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_gamification_select_own" ON "public"."user_gamification" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."user_notification_preferences" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_notification_preferences_insert_own" ON "public"."user_notification_preferences" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_notification_preferences_select_own" ON "public"."user_notification_preferences" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "user_notification_preferences_update_own" ON "public"."user_notification_preferences" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."user_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_ratings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_reviews" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_search_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."username_reserved" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."watch_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "watch_events_insert" ON "public"."watch_events" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "watch_events_select" ON "public"."watch_events" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "watch_events_update" ON "public"."watch_events" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



ALTER TABLE "public"."xp_transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "xp_transactions_select_own" ON "public"."xp_transactions" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."activities_refresh_completed"("p_user" "uuid", "p_show" integer, "p_completed_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activities_refresh_completed"("p_user" "uuid", "p_show" integer, "p_completed_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."activities_refresh_rated"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activities_refresh_rated"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."activities_refresh_watch"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer, "p_day" "date", "p_rewatch" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activities_refresh_watch"("p_user" "uuid", "p_media_type" "text", "p_tmdb" integer, "p_day" "date", "p_rewatch" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."activity_interaction_gate"("p_activity_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activity_interaction_gate"("p_activity_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_activity_comment"("p_activity_id" "uuid", "p_content" "text", "p_comment_id" "uuid", "p_parent_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_activity_comment"("p_activity_id" "uuid", "p_content" "text", "p_comment_id" "uuid", "p_parent_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."add_activity_comment"("p_activity_id" "uuid", "p_content" "text", "p_comment_id" "uuid", "p_parent_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."api_proxy_bump_hit"("p_provider" "text", "p_cache_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."api_proxy_bump_hit"("p_provider" "text", "p_cache_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."api_proxy_prune"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."api_proxy_prune"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."api_proxy_refund"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."api_proxy_refund"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."api_proxy_try_spend"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone, "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."api_proxy_try_spend"("p_provider" "text", "p_scope" "text", "p_window_start" timestamp with time zone, "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_mutations"("batch" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_mutations"("batch" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_mutations"("batch" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."award_xp"("p_action_type" "text", "p_source" "text", "p_is_pro" boolean, "p_custom_xp" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."award_xp"("p_action_type" "text", "p_source" "text", "p_is_pro" boolean, "p_custom_xp" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."award_xp"("p_action_type" "text", "p_source" "text", "p_is_pro" boolean, "p_custom_xp" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."backfill_watchlist_tracking"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."backfill_watchlist_tracking"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."block_list_owner"("p_list_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."block_list_owner"("p_list_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_list_owner"("p_list_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."block_user"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."block_user"("p_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."block_user"("p_user_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."calculate_quality_score"("p_youtube_views" integer, "p_tmdb_rating" double precision, "p_recency_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_quality_score"("p_youtube_views" integer, "p_tmdb_rating" double precision, "p_recency_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_quality_score"("p_youtube_views" integer, "p_tmdb_rating" double precision, "p_recency_days" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."catalog_shows_needing_refresh"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."catalog_shows_needing_refresh"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."catalog_store_tvdb_map"("p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."catalog_store_tvdb_map"("p_rows" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clean_old_webhook_logs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clean_old_webhook_logs"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_expired_cache"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_expired_cache"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_expired_discovery"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_expired_discovery"() TO "service_role";



GRANT ALL ON TABLE "public"."clip_comments" TO "anon";
GRANT ALL ON TABLE "public"."clip_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."clip_comments" TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "text", "p_comment_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "text", "p_comment_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "text", "p_comment_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "uuid", "p_comment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "uuid", "p_comment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_add_comment"("p_clip_id" "text", "p_content" "text", "p_parent_comment_id" "uuid", "p_comment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."clip_comment_like_count_dec"() TO "anon";
GRANT ALL ON FUNCTION "public"."clip_comment_like_count_dec"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_comment_like_count_dec"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clip_comment_like_count_inc"() TO "anon";
GRANT ALL ON FUNCTION "public"."clip_comment_like_count_inc"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_comment_like_count_inc"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clip_comments_clip_count_dec"() TO "anon";
GRANT ALL ON FUNCTION "public"."clip_comments_clip_count_dec"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_comments_clip_count_dec"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clip_comments_clip_count_inc"() TO "anon";
GRANT ALL ON FUNCTION "public"."clip_comments_clip_count_inc"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_comments_clip_count_inc"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clip_comments_reply_count_dec"() TO "anon";
GRANT ALL ON FUNCTION "public"."clip_comments_reply_count_dec"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_comments_reply_count_dec"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clip_comments_reply_count_inc"() TO "anon";
GRANT ALL ON FUNCTION "public"."clip_comments_reply_count_inc"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_comments_reply_count_inc"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_delete_comment"("p_comment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_delete_comment"("p_comment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_delete_comment"("p_comment_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "text", "p_like_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "text", "p_like_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "text", "p_like_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_toggle_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clip_toggle_reaction"("p_clip_id" "text", "p_reaction_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."compute_streak"("p_previous_date" "date", "p_today" "date", "p_current_streak" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."compute_streak"("p_previous_date" "date", "p_today" "date", "p_current_streak" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."compute_streak"("p_previous_date" "date", "p_today" "date", "p_current_streak" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_default_lists"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_default_lists"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_import_job"("p_storage_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_import_job"("p_storage_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_import_job"("p_storage_path" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."decay_preference_scores"("p_user_id" "uuid", "p_decay_rate" real) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."decay_preference_scores"("p_user_id" "uuid", "p_decay_rate" real) TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_activity_comment"("p_comment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_activity_comment"("p_comment_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."delete_activity_comment"("p_comment_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."enforce_custom_list_limit"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enforce_custom_list_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_is_pro_server_authoritative"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_is_pro_server_authoritative"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_is_pro_server_authoritative"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."expand_seen_shows_to_watch_events"("p_shows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expand_seen_shows_to_watch_events"("p_shows" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."expand_seen_shows_to_watch_events"("p_shows" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_activity_comments"("p_activity_id" "uuid", "p_limit" integer, "p_after" timestamp with time zone, "p_after_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_activity_comments"("p_activity_id" "uuid", "p_limit" integer, "p_after" timestamp with time zone, "p_after_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_activity_comments"("p_activity_id" "uuid", "p_limit" integer, "p_after" timestamp with time zone, "p_after_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_activity_feed"("p_scope" "text", "p_user" "uuid", "p_before" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer, "p_activity_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_activity_feed"("p_scope" "text", "p_user" "uuid", "p_before" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer, "p_activity_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_activity_feed"("p_scope" "text", "p_user" "uuid", "p_before" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer, "p_activity_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_ai_global_tokens_today"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_ai_global_tokens_today"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_ai_token_usage"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_ai_token_usage"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_ai_token_usage"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_list_items_with_providers"("p_list_id" "uuid", "p_country" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_list_items_with_providers"("p_list_id" "uuid", "p_country" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_list_items_with_providers"("p_list_id" "uuid", "p_country" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_stats"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_stats"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_my_stats"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_personalized_recommendations"("p_user_id" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_personalized_recommendations"("p_user_id" "uuid", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_personalized_recommendations"("p_user_id" "uuid", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_public_lists"("p_search" "text", "p_scope" "text", "p_limit" integer, "p_offset" integer, "p_owner" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_public_lists"("p_search" "text", "p_scope" "text", "p_limit" integer, "p_offset" integer, "p_owner" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_lists"("p_search" "text", "p_scope" "text", "p_limit" integer, "p_offset" integer, "p_owner" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_public_profile"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_public_profile"("p_username" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_public_profile"("p_username" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_user_profile_summary"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_user_profile_summary"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_profile_summary"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."hide_activity"("p_activity_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."hide_activity"("p_activity_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."hide_activity"("p_activity_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."import_apply_mutations"("p_user" "uuid", "batch" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_apply_mutations"("p_user" "uuid", "batch" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."import_exclude_unresolved"("p_job_id" "uuid", "p_tvdb_series_ids" "text"[], "p_movie_uuids" "text"[], "p_series_titles" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_exclude_unresolved"("p_job_id" "uuid", "p_tvdb_series_ids" "text"[], "p_movie_uuids" "text"[], "p_series_titles" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_exclude_unresolved"("p_job_id" "uuid", "p_tvdb_series_ids" "text"[], "p_movie_uuids" "text"[], "p_series_titles" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."import_reopen_manual_resolution"("p_job_id" "uuid", "p_tvdb_series_id" bigint, "p_tmdb_show_id" integer, "p_row_indexes" integer[], "p_totals" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_reopen_manual_resolution"("p_job_id" "uuid", "p_tvdb_series_id" bigint, "p_tmdb_show_id" integer, "p_row_indexes" integer[], "p_totals" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."import_reopen_manual_resolutions"("p_job_id" "uuid", "p_resolutions" "jsonb", "p_row_indexes" integer[], "p_totals" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_reopen_manual_resolutions"("p_job_id" "uuid", "p_resolutions" "jsonb", "p_row_indexes" integer[], "p_totals" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."import_report"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_report"("p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_report"("p_job_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."import_touched_shows"("p_job_id" "uuid", "p_after" integer, "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_touched_shows"("p_job_id" "uuid", "p_after" integer, "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."imports_stale_uploads"("p_older_than" interval) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."imports_stale_uploads"("p_older_than" interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_clip_views"("clip_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_clip_views"("clip_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_clip_views"("clip_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_special_episode"("season_number" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."is_special_episode"("season_number" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_special_episode"("season_number" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."level_for_xp"("p_xp" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."level_for_xp"("p_xp" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."level_for_xp"("p_xp" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_ai_global_tokens"("p_tokens" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_ai_global_tokens"("p_tokens" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_ai_request_usage"("p_user_id" "uuid", "p_bucket" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_ai_request_usage"("p_user_id" "uuid", "p_bucket" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_ai_request_usage"("p_user_id" "uuid", "p_bucket" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_ai_token_usage"("p_user_id" "uuid", "p_requests" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_ai_token_usage"("p_user_id" "uuid", "p_requests" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_ai_token_usage"("p_user_id" "uuid", "p_requests" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."merge_user_preferences"("p_user_id" "uuid", "p_preferences" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_user_preferences"("p_user_id" "uuid", "p_preferences" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_user_preferences"("p_user_id" "uuid", "p_preferences" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."prune_user_devices"("p_keep" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prune_user_devices"("p_keep" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."pseudonymize_revenuecat_logs"("p_user_id" "text", "p_pseudonym" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."pseudonymize_revenuecat_logs"("p_user_id" "text", "p_pseudonym" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."recompute_tv_show_state"("p_user_id" "uuid", "p_tmdb_show_id" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recompute_tv_show_state"("p_user_id" "uuid", "p_tmdb_show_id" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_backlog_since"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_backlog_since"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_movie_reaction_counts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_movie_reaction_counts"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."register_user_device"("p_fcm_token" "text", "p_platform" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_user_device"("p_fcm_token" "text", "p_platform" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_user_device"("p_fcm_token" "text", "p_platform" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."report_content"("p_content_type" "text", "p_content_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."report_content"("p_content_type" "text", "p_content_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."report_content"("p_content_type" "text", "p_content_id" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."reset_ai_token_usage"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reset_ai_token_usage"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_ai_token_usage"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_daily_quotas"() TO "anon";
GRANT ALL ON FUNCTION "public"."reset_daily_quotas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_daily_quotas"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."retry_import_job"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."retry_import_job"("p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."retry_import_job"("p_job_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."public_profiles" TO "anon";
GRANT ALL ON TABLE "public"."public_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."public_profiles" TO "service_role";



REVOKE ALL ON FUNCTION "public"."search_users"("p_query" "text", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_users"("p_query" "text", "p_limit" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."search_users"("p_query" "text", "p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_activity_feed_visibility"("p_enabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_activity_feed_visibility"("p_enabled" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."set_activity_feed_visibility"("p_enabled" boolean) TO "authenticated";



GRANT ALL ON FUNCTION "public"."set_clips_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_clips_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_clips_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_username"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_username"("p_username" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."set_username"("p_username" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."streak_multiplier_for_count"("p_streak" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."streak_multiplier_for_count"("p_streak" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."streak_multiplier_for_count"("p_streak" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."suggest_username"("p_name" "text", "p_fallback" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."suggest_username"("p_name" "text", "p_fallback" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_activity_comments_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_activity_comments_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_activity_likes_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_activity_likes_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_list_items_enroll_alert"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_list_items_enroll_alert"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_list_items_retire_alert"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_list_items_retire_alert"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_lists_activities"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_lists_activities"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_profiles_username_changed"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_profiles_username_changed"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_tv_show_state_activities"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_tv_show_state_activities"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_user_blocks_prune_follows"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_user_blocks_prune_follows"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_user_follows_blocked"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_user_follows_blocked"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_user_follows_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_user_follows_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_user_ratings_activities"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_user_ratings_activities"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_user_reviews_activities"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_user_reviews_activities"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_watch_events_activities"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_watch_events_activities"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."tg_watch_events_recompute"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tg_watch_events_recompute"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."toggle_activity_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."toggle_activity_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."toggle_activity_comment_like"("p_comment_id" "uuid", "p_like_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."toggle_activity_like"("p_activity_id" "uuid", "p_like_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."toggle_activity_like"("p_activity_id" "uuid", "p_like_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."toggle_activity_like"("p_activity_id" "uuid", "p_like_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."touch_import_job"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."touch_import_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tv_tracking_bucket"("p_user_status" "text", "p_watched_count" integer, "p_backlog_since" timestamp with time zone, "p_stale_after" interval) TO "anon";
GRANT ALL ON FUNCTION "public"."tv_tracking_bucket"("p_user_status" "text", "p_watched_count" integer, "p_backlog_since" timestamp with time zone, "p_stale_after" interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."tv_tracking_bucket"("p_user_status" "text", "p_watched_count" integer, "p_backlog_since" timestamp with time zone, "p_stale_after" interval) TO "service_role";



REVOKE ALL ON FUNCTION "public"."unsee_tv_show"("p_tmdb_show_id" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unsee_tv_show"("p_tmdb_show_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."unsee_tv_show"("p_tmdb_show_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."user_counts_specials"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_counts_specials"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."user_storage_objects"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_storage_objects"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."user_today"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_today"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."username_available"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."username_available"("p_username" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."username_available"("p_username" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."username_seed"("p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."username_seed"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."xp_base_for_action"("p_action_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."xp_base_for_action"("p_action_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."xp_base_for_action"("p_action_type" "text") TO "service_role";



GRANT ALL ON TABLE "public"."activities" TO "service_role";
GRANT SELECT ON TABLE "public"."activities" TO "authenticated";



GRANT ALL ON TABLE "public"."activity_comment_likes" TO "service_role";



GRANT ALL ON TABLE "public"."activity_comments" TO "service_role";



GRANT ALL ON TABLE "public"."activity_likes" TO "service_role";



GRANT ALL ON TABLE "public"."ai_conversation_history" TO "anon";
GRANT ALL ON TABLE "public"."ai_conversation_history" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_conversation_history" TO "service_role";



GRANT ALL ON TABLE "public"."ai_global_usage" TO "service_role";



GRANT ALL ON TABLE "public"."api_proxy_budget" TO "anon";
GRANT ALL ON TABLE "public"."api_proxy_budget" TO "authenticated";
GRANT ALL ON TABLE "public"."api_proxy_budget" TO "service_role";



GRANT ALL ON TABLE "public"."api_proxy_cache" TO "anon";
GRANT ALL ON TABLE "public"."api_proxy_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."api_proxy_cache" TO "service_role";



GRANT ALL ON TABLE "public"."clip_comment_likes" TO "anon";
GRANT ALL ON TABLE "public"."clip_comment_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."clip_comment_likes" TO "service_role";



GRANT ALL ON TABLE "public"."clip_reactions" TO "anon";
GRANT ALL ON TABLE "public"."clip_reactions" TO "authenticated";
GRANT ALL ON TABLE "public"."clip_reactions" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."clips" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."clips" TO "authenticated";
GRANT ALL ON TABLE "public"."clips" TO "service_role";



GRANT ALL ON TABLE "public"."content_reports" TO "service_role";



GRANT ALL ON TABLE "public"."device_info" TO "anon";
GRANT ALL ON TABLE "public"."device_info" TO "authenticated";
GRANT ALL ON TABLE "public"."device_info" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_cache" TO "anon";
GRANT ALL ON TABLE "public"."discovery_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_cache" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_warm_feeds" TO "anon";
GRANT ALL ON TABLE "public"."discovery_warm_feeds" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_warm_feeds" TO "service_role";



GRANT ALL ON TABLE "public"."email_send_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."email_send_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."email_send_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."email_send_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."global_discovery_filters" TO "anon";
GRANT ALL ON TABLE "public"."global_discovery_filters" TO "authenticated";
GRANT ALL ON TABLE "public"."global_discovery_filters" TO "service_role";



GRANT ALL ON TABLE "public"."health_check" TO "anon";
GRANT ALL ON TABLE "public"."health_check" TO "authenticated";
GRANT ALL ON TABLE "public"."health_check" TO "service_role";



GRANT ALL ON TABLE "public"."import_jobs" TO "anon";
GRANT ALL ON TABLE "public"."import_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."import_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."import_staging" TO "anon";
GRANT ALL ON TABLE "public"."import_staging" TO "authenticated";
GRANT ALL ON TABLE "public"."import_staging" TO "service_role";



GRANT ALL ON TABLE "public"."list_follows" TO "anon";
GRANT ALL ON TABLE "public"."list_follows" TO "authenticated";
GRANT ALL ON TABLE "public"."list_follows" TO "service_role";



GRANT ALL ON TABLE "public"."list_items" TO "anon";
GRANT ALL ON TABLE "public"."list_items" TO "authenticated";
GRANT ALL ON TABLE "public"."list_items" TO "service_role";



GRANT ALL ON TABLE "public"."list_reports" TO "anon";
GRANT ALL ON TABLE "public"."list_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."list_reports" TO "service_role";



GRANT ALL ON TABLE "public"."lists" TO "anon";
GRANT ALL ON TABLE "public"."lists" TO "authenticated";
GRANT ALL ON TABLE "public"."lists" TO "service_role";



GRANT ALL ON TABLE "public"."media_availability" TO "anon";
GRANT ALL ON TABLE "public"."media_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."media_availability" TO "service_role";



GRANT ALL ON TABLE "public"."media_details_cache" TO "anon";
GRANT ALL ON TABLE "public"."media_details_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."media_details_cache" TO "service_role";



GRANT ALL ON TABLE "public"."movie_reaction_counts" TO "anon";
GRANT ALL ON TABLE "public"."movie_reaction_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."movie_reaction_counts" TO "service_role";



GRANT ALL ON TABLE "public"."movie_reactions" TO "anon";
GRANT ALL ON TABLE "public"."movie_reactions" TO "authenticated";
GRANT ALL ON TABLE "public"."movie_reactions" TO "service_role";



GRANT ALL ON TABLE "public"."notification_delivery_log" TO "anon";
GRANT ALL ON TABLE "public"."notification_delivery_log" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_delivery_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notification_delivery_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notification_delivery_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notification_delivery_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."personalized_discovery" TO "anon";
GRANT ALL ON TABLE "public"."personalized_discovery" TO "authenticated";
GRANT ALL ON TABLE "public"."personalized_discovery" TO "service_role";



GRANT ALL ON TABLE "public"."revenuecat_webhook_logs" TO "anon";
GRANT ALL ON TABLE "public"."revenuecat_webhook_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."revenuecat_webhook_logs" TO "service_role";



GRANT ALL ON TABLE "public"."recent_webhook_activity" TO "anon";
GRANT ALL ON TABLE "public"."recent_webhook_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."recent_webhook_activity" TO "service_role";



GRANT ALL ON TABLE "public"."release_alerts" TO "anon";
GRANT ALL ON TABLE "public"."release_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."release_alerts" TO "service_role";



GRANT ALL ON TABLE "public"."sync_rejected_mutations" TO "service_role";



GRANT ALL ON TABLE "public"."tmdb_episodes" TO "anon";
GRANT ALL ON TABLE "public"."tmdb_episodes" TO "authenticated";
GRANT ALL ON TABLE "public"."tmdb_episodes" TO "service_role";



GRANT ALL ON TABLE "public"."tmdb_shows" TO "anon";
GRANT ALL ON TABLE "public"."tmdb_shows" TO "authenticated";
GRANT ALL ON TABLE "public"."tmdb_shows" TO "service_role";



GRANT ALL ON TABLE "public"."trailers_cache" TO "anon";
GRANT ALL ON TABLE "public"."trailers_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."trailers_cache" TO "service_role";



GRANT ALL ON TABLE "public"."tv_show_state" TO "anon";
GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."tv_show_state" TO "authenticated";
GRANT ALL ON TABLE "public"."tv_show_state" TO "service_role";



GRANT INSERT("user_id") ON TABLE "public"."tv_show_state" TO "authenticated";



GRANT INSERT("tmdb_show_id") ON TABLE "public"."tv_show_state" TO "authenticated";



GRANT INSERT("user_status"),UPDATE("user_status") ON TABLE "public"."tv_show_state" TO "authenticated";



GRANT ALL ON TABLE "public"."tvdb_tmdb_map" TO "anon";
GRANT ALL ON TABLE "public"."tvdb_tmdb_map" TO "authenticated";
GRANT ALL ON TABLE "public"."tvdb_tmdb_map" TO "service_role";



GRANT ALL ON TABLE "public"."unified_user_preferences" TO "anon";
GRANT ALL ON TABLE "public"."unified_user_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."unified_user_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."user_ai_token_usage" TO "anon";
GRANT ALL ON TABLE "public"."user_ai_token_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."user_ai_token_usage" TO "service_role";



GRANT ALL ON TABLE "public"."user_badges" TO "anon";
GRANT ALL ON TABLE "public"."user_badges" TO "authenticated";
GRANT ALL ON TABLE "public"."user_badges" TO "service_role";



GRANT ALL ON TABLE "public"."user_blocks" TO "anon";
GRANT ALL ON TABLE "public"."user_blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."user_blocks" TO "service_role";



GRANT ALL ON TABLE "public"."user_clip_history" TO "anon";
GRANT ALL ON TABLE "public"."user_clip_history" TO "authenticated";
GRANT ALL ON TABLE "public"."user_clip_history" TO "service_role";



GRANT ALL ON TABLE "public"."user_clip_signals" TO "anon";
GRANT ALL ON TABLE "public"."user_clip_signals" TO "authenticated";
GRANT ALL ON TABLE "public"."user_clip_signals" TO "service_role";



GRANT ALL ON TABLE "public"."user_daily_challenges" TO "anon";
GRANT ALL ON TABLE "public"."user_daily_challenges" TO "authenticated";
GRANT ALL ON TABLE "public"."user_daily_challenges" TO "service_role";



GRANT ALL ON TABLE "public"."user_daily_quota" TO "anon";
GRANT ALL ON TABLE "public"."user_daily_quota" TO "authenticated";
GRANT ALL ON TABLE "public"."user_daily_quota" TO "service_role";



GRANT ALL ON TABLE "public"."user_devices" TO "anon";
GRANT ALL ON TABLE "public"."user_devices" TO "authenticated";
GRANT ALL ON TABLE "public"."user_devices" TO "service_role";



GRANT ALL ON TABLE "public"."user_discovery_interactions" TO "anon";
GRANT ALL ON TABLE "public"."user_discovery_interactions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_discovery_interactions" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."user_entitlements" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."user_entitlements" TO "authenticated";
GRANT ALL ON TABLE "public"."user_entitlements" TO "service_role";



GRANT ALL ON TABLE "public"."user_favorites" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."user_favorites" TO "authenticated";



GRANT ALL ON TABLE "public"."user_follows" TO "authenticated";
GRANT ALL ON TABLE "public"."user_follows" TO "service_role";



GRANT ALL ON TABLE "public"."user_gamification" TO "anon";
GRANT ALL ON TABLE "public"."user_gamification" TO "authenticated";
GRANT ALL ON TABLE "public"."user_gamification" TO "service_role";



GRANT ALL ON TABLE "public"."user_notification_preferences" TO "anon";
GRANT ALL ON TABLE "public"."user_notification_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."user_notification_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."user_preferences" TO "anon";
GRANT ALL ON TABLE "public"."user_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."user_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."user_ratings" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."user_ratings" TO "authenticated";



GRANT ALL ON TABLE "public"."user_reviews" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."user_reviews" TO "authenticated";



GRANT ALL ON TABLE "public"."user_search_history" TO "anon";
GRANT ALL ON TABLE "public"."user_search_history" TO "authenticated";
GRANT ALL ON TABLE "public"."user_search_history" TO "service_role";



GRANT ALL ON TABLE "public"."username_reserved" TO "anon";
GRANT ALL ON TABLE "public"."username_reserved" TO "authenticated";
GRANT ALL ON TABLE "public"."username_reserved" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_cache_hit_rate" TO "anon";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_cache_hit_rate" TO "authenticated";
GRANT ALL ON TABLE "public"."v_cache_hit_rate" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_notifications_health" TO "anon";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_notifications_health" TO "authenticated";
GRANT ALL ON TABLE "public"."v_notifications_health" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_sync_outbox_health" TO "anon";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_sync_outbox_health" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sync_outbox_health" TO "service_role";



GRANT ALL ON TABLE "public"."v_tv_timeline" TO "authenticated";
GRANT ALL ON TABLE "public"."v_tv_timeline" TO "service_role";



GRANT ALL ON TABLE "public"."v_tv_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."v_tv_tracking" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_user_engagement" TO "anon";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."v_user_engagement" TO "authenticated";
GRANT ALL ON TABLE "public"."v_user_engagement" TO "service_role";



GRANT ALL ON TABLE "public"."watch_events" TO "anon";
GRANT ALL ON TABLE "public"."watch_events" TO "authenticated";
GRANT ALL ON TABLE "public"."watch_events" TO "service_role";



GRANT ALL ON TABLE "public"."xp_transactions" TO "anon";
GRANT ALL ON TABLE "public"."xp_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."xp_transactions" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";









-- ---------------------------------------------------------------------
-- Aggiunto a mano: revoche non emesse da pg_dump.
--
-- Supabase ha ALTER DEFAULT PRIVILEGES che concede ALL su ogni nuova
-- tabella di `public` ad anon e authenticated. Il progetto ha poi revocato
-- caso per caso, ma pg_dump emette solo i GRANT risultanti: ricostruendo da
-- zero le tabelle rinascerebbero con i privilegi di default e la revoca
-- sparirebbe in silenzio. Senza queste righe un DB ricostruito darebbe ad
-- anon la SELECT su activities, content_reports, user_ratings e altre.
--
-- Elenco prodotto da `supabase db diff --linked --schema public`.
-- ---------------------------------------------------------------------

revoke delete on table "public"."activities" from "anon";
revoke insert on table "public"."activities" from "anon";
revoke references on table "public"."activities" from "anon";
revoke select on table "public"."activities" from "anon";
revoke trigger on table "public"."activities" from "anon";
revoke truncate on table "public"."activities" from "anon";
revoke update on table "public"."activities" from "anon";
revoke delete on table "public"."activities" from "authenticated";
revoke insert on table "public"."activities" from "authenticated";
revoke references on table "public"."activities" from "authenticated";
revoke trigger on table "public"."activities" from "authenticated";
revoke truncate on table "public"."activities" from "authenticated";
revoke update on table "public"."activities" from "authenticated";
revoke delete on table "public"."activity_comment_likes" from "anon";
revoke insert on table "public"."activity_comment_likes" from "anon";
revoke references on table "public"."activity_comment_likes" from "anon";
revoke select on table "public"."activity_comment_likes" from "anon";
revoke trigger on table "public"."activity_comment_likes" from "anon";
revoke truncate on table "public"."activity_comment_likes" from "anon";
revoke update on table "public"."activity_comment_likes" from "anon";
revoke delete on table "public"."activity_comment_likes" from "authenticated";
revoke insert on table "public"."activity_comment_likes" from "authenticated";
revoke references on table "public"."activity_comment_likes" from "authenticated";
revoke select on table "public"."activity_comment_likes" from "authenticated";
revoke trigger on table "public"."activity_comment_likes" from "authenticated";
revoke truncate on table "public"."activity_comment_likes" from "authenticated";
revoke update on table "public"."activity_comment_likes" from "authenticated";
revoke delete on table "public"."activity_comments" from "anon";
revoke insert on table "public"."activity_comments" from "anon";
revoke references on table "public"."activity_comments" from "anon";
revoke select on table "public"."activity_comments" from "anon";
revoke trigger on table "public"."activity_comments" from "anon";
revoke truncate on table "public"."activity_comments" from "anon";
revoke update on table "public"."activity_comments" from "anon";
revoke delete on table "public"."activity_comments" from "authenticated";
revoke insert on table "public"."activity_comments" from "authenticated";
revoke references on table "public"."activity_comments" from "authenticated";
revoke select on table "public"."activity_comments" from "authenticated";
revoke trigger on table "public"."activity_comments" from "authenticated";
revoke truncate on table "public"."activity_comments" from "authenticated";
revoke update on table "public"."activity_comments" from "authenticated";
revoke delete on table "public"."activity_likes" from "anon";
revoke insert on table "public"."activity_likes" from "anon";
revoke references on table "public"."activity_likes" from "anon";
revoke select on table "public"."activity_likes" from "anon";
revoke trigger on table "public"."activity_likes" from "anon";
revoke truncate on table "public"."activity_likes" from "anon";
revoke update on table "public"."activity_likes" from "anon";
revoke delete on table "public"."activity_likes" from "authenticated";
revoke insert on table "public"."activity_likes" from "authenticated";
revoke references on table "public"."activity_likes" from "authenticated";
revoke select on table "public"."activity_likes" from "authenticated";
revoke trigger on table "public"."activity_likes" from "authenticated";
revoke truncate on table "public"."activity_likes" from "authenticated";
revoke update on table "public"."activity_likes" from "authenticated";
revoke delete on table "public"."ai_global_usage" from "anon";
revoke insert on table "public"."ai_global_usage" from "anon";
revoke references on table "public"."ai_global_usage" from "anon";
revoke select on table "public"."ai_global_usage" from "anon";
revoke trigger on table "public"."ai_global_usage" from "anon";
revoke truncate on table "public"."ai_global_usage" from "anon";
revoke update on table "public"."ai_global_usage" from "anon";
revoke delete on table "public"."ai_global_usage" from "authenticated";
revoke insert on table "public"."ai_global_usage" from "authenticated";
revoke references on table "public"."ai_global_usage" from "authenticated";
revoke select on table "public"."ai_global_usage" from "authenticated";
revoke trigger on table "public"."ai_global_usage" from "authenticated";
revoke truncate on table "public"."ai_global_usage" from "authenticated";
revoke update on table "public"."ai_global_usage" from "authenticated";
revoke delete on table "public"."clips" from "anon";
revoke insert on table "public"."clips" from "anon";
revoke references on table "public"."clips" from "anon";
revoke trigger on table "public"."clips" from "anon";
revoke truncate on table "public"."clips" from "anon";
revoke update on table "public"."clips" from "anon";
revoke delete on table "public"."clips" from "authenticated";
revoke insert on table "public"."clips" from "authenticated";
revoke references on table "public"."clips" from "authenticated";
revoke trigger on table "public"."clips" from "authenticated";
revoke truncate on table "public"."clips" from "authenticated";
revoke update on table "public"."clips" from "authenticated";
revoke delete on table "public"."content_reports" from "anon";
revoke insert on table "public"."content_reports" from "anon";
revoke references on table "public"."content_reports" from "anon";
revoke select on table "public"."content_reports" from "anon";
revoke trigger on table "public"."content_reports" from "anon";
revoke truncate on table "public"."content_reports" from "anon";
revoke update on table "public"."content_reports" from "anon";
revoke delete on table "public"."content_reports" from "authenticated";
revoke insert on table "public"."content_reports" from "authenticated";
revoke references on table "public"."content_reports" from "authenticated";
revoke select on table "public"."content_reports" from "authenticated";
revoke trigger on table "public"."content_reports" from "authenticated";
revoke truncate on table "public"."content_reports" from "authenticated";
revoke update on table "public"."content_reports" from "authenticated";
revoke delete on table "public"."email_send_log" from "anon";
revoke insert on table "public"."email_send_log" from "anon";
revoke references on table "public"."email_send_log" from "anon";
revoke select on table "public"."email_send_log" from "anon";
revoke trigger on table "public"."email_send_log" from "anon";
revoke truncate on table "public"."email_send_log" from "anon";
revoke update on table "public"."email_send_log" from "anon";
revoke delete on table "public"."email_send_log" from "authenticated";
revoke insert on table "public"."email_send_log" from "authenticated";
revoke references on table "public"."email_send_log" from "authenticated";
revoke select on table "public"."email_send_log" from "authenticated";
revoke trigger on table "public"."email_send_log" from "authenticated";
revoke truncate on table "public"."email_send_log" from "authenticated";
revoke update on table "public"."email_send_log" from "authenticated";
revoke delete on table "public"."sync_rejected_mutations" from "anon";
revoke insert on table "public"."sync_rejected_mutations" from "anon";
revoke references on table "public"."sync_rejected_mutations" from "anon";
revoke select on table "public"."sync_rejected_mutations" from "anon";
revoke trigger on table "public"."sync_rejected_mutations" from "anon";
revoke truncate on table "public"."sync_rejected_mutations" from "anon";
revoke update on table "public"."sync_rejected_mutations" from "anon";
revoke delete on table "public"."sync_rejected_mutations" from "authenticated";
revoke insert on table "public"."sync_rejected_mutations" from "authenticated";
revoke references on table "public"."sync_rejected_mutations" from "authenticated";
revoke select on table "public"."sync_rejected_mutations" from "authenticated";
revoke trigger on table "public"."sync_rejected_mutations" from "authenticated";
revoke truncate on table "public"."sync_rejected_mutations" from "authenticated";
revoke update on table "public"."sync_rejected_mutations" from "authenticated";
revoke insert on table "public"."tv_show_state" from "authenticated";
revoke update on table "public"."tv_show_state" from "authenticated";
revoke delete on table "public"."user_entitlements" from "anon";
revoke insert on table "public"."user_entitlements" from "anon";
revoke truncate on table "public"."user_entitlements" from "anon";
revoke update on table "public"."user_entitlements" from "anon";
revoke delete on table "public"."user_entitlements" from "authenticated";
revoke insert on table "public"."user_entitlements" from "authenticated";
revoke truncate on table "public"."user_entitlements" from "authenticated";
revoke update on table "public"."user_entitlements" from "authenticated";
revoke delete on table "public"."user_favorites" from "anon";
revoke insert on table "public"."user_favorites" from "anon";
revoke references on table "public"."user_favorites" from "anon";
revoke select on table "public"."user_favorites" from "anon";
revoke trigger on table "public"."user_favorites" from "anon";
revoke truncate on table "public"."user_favorites" from "anon";
revoke update on table "public"."user_favorites" from "anon";
revoke delete on table "public"."user_favorites" from "authenticated";
revoke references on table "public"."user_favorites" from "authenticated";
revoke trigger on table "public"."user_favorites" from "authenticated";
revoke truncate on table "public"."user_favorites" from "authenticated";
revoke delete on table "public"."user_follows" from "anon";
revoke insert on table "public"."user_follows" from "anon";
revoke references on table "public"."user_follows" from "anon";
revoke select on table "public"."user_follows" from "anon";
revoke trigger on table "public"."user_follows" from "anon";
revoke truncate on table "public"."user_follows" from "anon";
revoke update on table "public"."user_follows" from "anon";
revoke delete on table "public"."user_ratings" from "anon";
revoke insert on table "public"."user_ratings" from "anon";
revoke references on table "public"."user_ratings" from "anon";
revoke select on table "public"."user_ratings" from "anon";
revoke trigger on table "public"."user_ratings" from "anon";
revoke truncate on table "public"."user_ratings" from "anon";
revoke update on table "public"."user_ratings" from "anon";
revoke delete on table "public"."user_ratings" from "authenticated";
revoke references on table "public"."user_ratings" from "authenticated";
revoke trigger on table "public"."user_ratings" from "authenticated";
revoke truncate on table "public"."user_ratings" from "authenticated";
revoke delete on table "public"."user_reviews" from "anon";
revoke insert on table "public"."user_reviews" from "anon";
revoke references on table "public"."user_reviews" from "anon";
revoke select on table "public"."user_reviews" from "anon";
revoke trigger on table "public"."user_reviews" from "anon";
revoke truncate on table "public"."user_reviews" from "anon";
revoke update on table "public"."user_reviews" from "anon";
revoke delete on table "public"."user_reviews" from "authenticated";
revoke references on table "public"."user_reviews" from "authenticated";
revoke trigger on table "public"."user_reviews" from "authenticated";
revoke truncate on table "public"."user_reviews" from "authenticated";
