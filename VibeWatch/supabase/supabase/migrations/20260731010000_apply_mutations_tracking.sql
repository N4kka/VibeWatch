-- SPEC v3 §4 / §7.2 — `apply_mutations` impara `watch_events` e `tv_show_state`.
--
-- Senza questo ramo ogni scrittura del client su quelle due tabelle finiva nel ramo finale
-- `table_not_handled`, cioe' in `sync_rejected_mutations`: non un errore rumoroso, ma una riga
-- in una tabella di scarto che nessuno guarda. E' lo stesso modo di perdere dati contro cui
-- mette in guardia P1, solo sul lato server — e sarebbe successo al primo "segna visto" del
-- blocco 5 e a ogni evento dell'import (§7.2 fase 4 scrive proprio via apply_mutations).
--
-- Il resto della funzione e' identico a quella in produzione.
--
-- ATTENZIONE all'ordine delle migration in questa cartella: `movie_reactions` (20260723135625) e
-- `unified_user_preferences` (20260723205456 in remoto, 20260723140500 come file) sono state
-- aggiunte per splice sul `prosrc`, ma i due file che riscrivono la funzione intera
-- (`_complete`, `_per_item_isolation`) hanno un nome che li mette DOPO. In produzione l'ordine
-- di applicazione reale era l'inverso e i due rami ci sono; replicando i file da zero
-- sparirebbero. Questo file li ricopia dal `prosrc` reale, cosi' le due strade convergono: e' la
-- definizione completa, ed essendo l'ultima vince in entrambi i casi.

create or replace function public.apply_mutations(batch jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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

      if v_write and (rec->>'user_id') is distinct from v_uid::text then
        v_handled := false;
        v_reason := 'user_id_mismatch';

      elsif tbl = 'lists' then
        if v_write then
          insert into public.lists as t
            (id, user_id, name, description, type, is_public, created_at, updated_at, deleted_at, synced_at)
          values
            ((rec->>'id')::uuid, (rec->>'user_id')::uuid, rec->>'name', rec->>'description', rec->>'type',
             (coalesce((rec->>'is_public')::boolean, false) and (rec->>'type') = 'custom'),
             (rec->>'created_at')::timestamptz, (rec->>'updated_at')::timestamptz,
             (rec->>'deleted_at')::timestamptz, now())
          on conflict (id) do update set
            name = excluded.name,
            description = excluded.description,
            type = excluded.type,
            is_public = (coalesce((rec->>'is_public')::boolean, t.is_public) and excluded.type = 'custom'),
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at,
            synced_at = now()
          where t.user_id = v_uid;
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
$function$;

revoke all on function public.apply_mutations(jsonb) from anon;
