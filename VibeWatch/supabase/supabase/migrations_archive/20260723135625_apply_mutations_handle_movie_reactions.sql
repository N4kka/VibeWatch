-- STAB-011: ora che public.movie_reactions esiste, l'outbox puo' essere servita invece di
-- finire in sync_rejected_mutations con reason='table_not_handled'.
-- Invariante di dc19d6a rispettato: la tabella ha un branch perche' la RLS del chiamante gia'
-- consente quella scrittura (policy insert/update/delete scopate a auth.uid()).
--
-- La funzione viene modificata partendo dalla sua definizione REALE (pg_proc.prosrc) con una
-- sostituzione mirata, non riscritta a memoria: e' la lezione di SEC-005, dove riscrivere
-- award_xp "a memoria" aveva inventato una helper inesistente e rotto la funzione.
do $$
declare
  src text;
  newsrc text;
  marker text := E'      elsif tbl in (''user_gamification'',''xp_transactions'') then';
  branch text := E'      elsif tbl = ''movie_reactions'' then\n'
    || E'        if v_write then\n'
    || E'          if coalesce(rec->>''media_id'','''') = '''' or coalesce(rec->>''media_type'','''') = ''''\n'
    || E'             or coalesce(rec->>''reaction_type'','''') = '''' then\n'
    || E'            v_handled := false;\n'
    || E'            v_reason := ''missing_required_field'';\n'
    || E'          else\n'
    || E'            insert into public.movie_reactions as t\n'
    || E'              (id, user_id, media_id, media_type, reaction_type, created_at, updated_at, deleted_at, synced_at)\n'
    || E'            values\n'
    || E'              (coalesce(nullif(rec->>''id'','''')::uuid, gen_random_uuid()), v_uid,\n'
    || E'               (rec->>''media_id'')::int, rec->>''media_type'', rec->>''reaction_type'',\n'
    || E'               coalesce(nullif(rec->>''created_at'','''')::timestamptz, now()),\n'
    || E'               coalesce(nullif(rec->>''updated_at'','''')::timestamptz, now()),\n'
    || E'               nullif(rec->>''deleted_at'','''')::timestamptz, now())\n'
    || E'            on conflict (user_id, media_id, media_type) do update set\n'
    || E'              reaction_type = excluded.reaction_type,\n'
    || E'              updated_at = excluded.updated_at,\n'
    || E'              deleted_at = excluded.deleted_at,\n'
    || E'              synced_at = now()\n'
    || E'            where t.user_id = v_uid;\n'
    || E'          end if;\n'
    || E'        elsif op = ''DELETE'' then\n'
    || E'          delete from public.movie_reactions where id = rec_id::uuid and user_id = v_uid;\n'
    || E'        end if;\n\n';
begin
  select prosrc into src from pg_proc where proname = 'apply_mutations';
  if src is null then raise exception 'apply_mutations non trovata'; end if;
  if position('movie_reactions' in src) > 0 then
    raise exception 'branch movie_reactions gia presente: interrompo per non duplicarlo';
  end if;
  if position(marker in src) = 0 then
    raise exception 'marker di inserimento non trovato: la funzione e cambiata, rivedere la patch';
  end if;

  newsrc := replace(src, marker, branch || marker);

  execute format(
    'create or replace function public.apply_mutations(batch jsonb) returns void '
    'language plpgsql security definer set search_path to ''public'' as %L', newsrc);
end $$;

-- La guardia di SEC-002/SEC-008 va riaffermata: CREATE OR REPLACE non tocca i grant, ma
-- rendiamolo esplicito e idempotente.
revoke execute on function public.apply_mutations(jsonb) from anon;
