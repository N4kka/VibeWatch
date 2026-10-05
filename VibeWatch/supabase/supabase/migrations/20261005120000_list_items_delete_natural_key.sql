-- apply_mutations: a list_items DELETE also matches on the natural key (list_id, media_id,
-- media_type) when the client sends it.
--
-- When a local INSERT was rejected with list_items_list_id_media_id_media_type_key, the device
-- and the server hold the same title in the same list under two different ids. Deleting by id
-- then touched nothing on the server, the next pull brought the row back, and a movie marked
-- watched reappeared in the watchlist. Older clients send only the id and keep the old behaviour.
--
-- The CASE is deliberate: it guarantees the casts only run on values that look like a uuid and
-- an integer. A plain AND gives no evaluation-order guarantee, and a failed cast would reject the
-- whole item — the id path included.
--
-- Spliced onto the live prosrc, never rewritten (see the deploy notes).
do $splice$
declare
  v_src text;
  v_def text;
  v_old text := 'delete from public.list_items where id = rec_id::uuid and user_id = v_uid;';
  v_new text := 'delete from public.list_items
          where user_id = v_uid
            and (id = rec_id::uuid
                 or case when coalesce(rec->>''list_id'', '''') ~* ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$''
                              and coalesce(rec->>''media_id'', '''') ~ ''^[0-9]+$''
                              and rec->>''media_type'' in (''movie'', ''tv'')
                         then list_id = (rec->>''list_id'')::uuid
                              and media_id = (rec->>''media_id'')::int
                              and media_type = rec->>''media_type''
                         else false
                    end);';
begin
  select p.prosrc, pg_get_functiondef(p.oid) into v_src, v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'apply_mutations';

  if position(v_new in v_src) > 0 then
    return; -- already applied
  end if;
  if md5(v_src) <> 'ed109979236245403b07596f21a2906a' then
    raise exception 'apply_mutations changed since this splice was written (md5 %)', md5(v_src);
  end if;
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'apply_mutations: splice anchor not found exactly once';
  end if;

  execute replace(v_def, v_old, v_new);
end
$splice$;
