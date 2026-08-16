-- STAB-010: unified_user_preferences aveva un push malformato dal client (niente user_id, nomi
-- colonna sbagliati, id non-uuid) e nessun branch in apply_mutations -> sync fermo dal 2026-05-17.
-- Il client ora pusha la riga reale persistita (colonne giuste, uuid, valori assoluti); qui si
-- aggiunge il branch. Invariante dc19d6a rispettato: RLS INSERT/UPDATE gia' scopata a
-- auth.uid() = user_id. device_id default 'unknown' come gli altri branch (colonna NOT NULL).
-- Modifica per sostituzione mirata sul sorgente reale (lezione SEC-005), non riscrittura a memoria.
do $$
declare
  src text;
  newsrc text;
  marker text := E'      elsif tbl in (''user_gamification'',''xp_transactions'') then';
  branch text := E'      elsif tbl = ''unified_user_preferences'' then\n'
    || E'        if v_write then\n'
    || E'          if coalesce(rec->>''preference_category'','''') = '''' or coalesce(rec->>''preference_id'','''') = '''' then\n'
    || E'            v_handled := false;\n'
    || E'            v_reason := ''missing_required_field'';\n'
    || E'          else\n'
    || E'            insert into public.unified_user_preferences as t\n'
    || E'              (id, user_id, device_id, preference_category, preference_id, preference_name,\n'
    || E'               score, score_from_clips, score_from_discovery, score_from_search, score_from_ai,\n'
    || E'               score_from_lists, interaction_count, last_interaction_at, created_at, updated_at)\n'
    || E'            values\n'
    || E'              (coalesce(nullif(rec->>''id'','''')::uuid, gen_random_uuid()), v_uid,\n'
    || E'               coalesce(nullif(rec->>''device_id'',''''),''unknown''), rec->>''preference_category'', rec->>''preference_id'',\n'
    || E'               rec->>''preference_name'',\n'
    || E'               coalesce(nullif(rec->>''score'','''')::real, 0),\n'
    || E'               coalesce(nullif(rec->>''score_from_clips'','''')::real, 0),\n'
    || E'               coalesce(nullif(rec->>''score_from_discovery'','''')::real, 0),\n'
    || E'               coalesce(nullif(rec->>''score_from_search'','''')::real, 0),\n'
    || E'               coalesce(nullif(rec->>''score_from_ai'','''')::real, 0),\n'
    || E'               coalesce(nullif(rec->>''score_from_lists'','''')::real, 0),\n'
    || E'               coalesce(nullif(rec->>''interaction_count'','''')::int, 0),\n'
    || E'               nullif(rec->>''last_interaction_at'','''')::timestamptz,\n'
    || E'               now(),\n'
    || E'               coalesce(nullif(rec->>''updated_at'','''')::timestamptz, now()))\n'
    || E'            on conflict (user_id, preference_category, preference_id) do update set\n'
    || E'              preference_name = excluded.preference_name,\n'
    || E'              score = excluded.score,\n'
    || E'              score_from_clips = excluded.score_from_clips,\n'
    || E'              score_from_discovery = excluded.score_from_discovery,\n'
    || E'              score_from_search = excluded.score_from_search,\n'
    || E'              score_from_ai = excluded.score_from_ai,\n'
    || E'              score_from_lists = excluded.score_from_lists,\n'
    || E'              interaction_count = excluded.interaction_count,\n'
    || E'              last_interaction_at = excluded.last_interaction_at,\n'
    || E'              updated_at = excluded.updated_at\n'
    || E'            where t.user_id = v_uid;\n'
    || E'          end if;\n'
    || E'        elsif op = ''DELETE'' then\n'
    || E'          delete from public.unified_user_preferences where id = rec_id::uuid and user_id = v_uid;\n'
    || E'        end if;\n\n';
begin
  select prosrc into src from pg_proc where proname = 'apply_mutations';
  if src is null then raise exception 'apply_mutations non trovata'; end if;
  if position('unified_user_preferences' in src) > 0 then
    raise exception 'branch unified_user_preferences gia presente';
  end if;
  if position(marker in src) = 0 then
    raise exception 'marker non trovato: la funzione e cambiata';
  end if;
  newsrc := replace(src, marker, branch || marker);
  execute format(
    'create or replace function public.apply_mutations(batch jsonb) returns void '
    'language plpgsql security definer set search_path to ''public'' as %L', newsrc);
end $$;

revoke execute on function public.apply_mutations(jsonb) from anon;
