-- Social feed M3 — "rimuovi dal feed" e la card raggiungibile per id.
--
-- **Perché `hidden_at` e non `deleted_at`.** Su `activities`, `deleted_at` è vocabolario dei
-- trigger: vuol dire "il gesto non esiste più" (l'ultimo episodio di quel giorno cancellato, il
-- voto tolto). E i refresh riscrivono la riga con `deleted_at = null` a ogni upsert — una
-- rimozione manuale scritta lì resusciterebbe al prossimo episodio guardato lo stesso giorno,
-- e l'utente si ritroverebbe nel feed una card che aveva tolto. `hidden_at` è invece volontà
-- dell'utente: nessun trigger la tocca, quindi sopravvive a qualunque ricalcolo. Due colonne
-- perché sono due fatti diversi, non due nomi per lo stesso.
--
-- **Un solo posto per il gate.** Aprire una card dalla notifica ha bisogno esattamente delle
-- stesse regole del feed (profilo pubblico, consenso, blocchi nei due versi, velo sulle review
-- segnalate): invece di duplicarle in una seconda funzione destinata a divergere alla prima
-- modifica, `get_activity_feed` prende un `p_activity_id`. Quando è valorizzato, scope e
-- cursore non contano — è una riga per id, con lo stesso gate di sempre.
--
-- La vecchia firma a 5 argomenti va DROPPATA, non solo sostituita: con entrambe vive ogni
-- chiamata a parametri nominati (come quelle del client) fallirebbe con "function is not
-- unique". Drop e create stanno nella stessa transazione della migration: nessuna finestra
-- in cui il feed resta senza funzione.

alter table public.activities add column if not exists hidden_at timestamptz;

comment on column public.activities.hidden_at is
  'Social feed M3: l''utente ha tolto QUESTA card dal feed (hide_activity). Diverso da '
  'deleted_at, che è la lapide dei trigger quando il gesto sottostante sparisce: i refresh '
  'azzerano deleted_at a ogni upsert, hidden_at non lo tocca nessuno.';

-- ------------------------------------------------------------------------- hide_activity
--
-- Idempotente: la seconda chiamata sulla stessa card risponde ancora `true` (è nascosta, che
-- è ciò che il chiamante voleva sapere) senza spostare il timbro. Solo il proprietario: su una
-- card altrui l'update non trova righe e la risposta è `false` — nessun messaggio diverso fra
-- "non è tua" e "non esiste", che sarebbe un modo per sondare l'esistenza delle attività altrui.
create or replace function public.hide_activity(p_activity_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
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

comment on function public.hide_activity(uuid) is
  'Social feed M3: toglie dal feed una PROPRIA attività (hidden_at). Idempotente; false se la '
  'card non esiste o non è del chiamante.';

revoke all on function public.hide_activity(uuid) from public;
revoke all on function public.hide_activity(uuid) from anon;
revoke all on function public.hide_activity(uuid) from authenticated;
grant execute on function public.hide_activity(uuid) to authenticated;

-- ------------------------------------------------------- il gate delle interazioni si allinea
--
-- Una card nascosta non è più una superficie sociale: niente like né commenti nuovi, nemmeno
-- da chi si era tenuto aperto il foglio. Stessa risposta dell'inesistente, come per i blocchi.
create or replace function public.activity_interaction_gate(p_activity_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
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

-- ------------------------------------------------------------------------ get_activity_feed
--
-- Rispetto alla M2 cambiano tre cose e basta: `hidden_at is null` nel where, il parametro
-- `p_activity_id` in coda (le chiamate esistenti a 5 parametri nominati restano valide) e il
-- corto circuito su scope/cursore quando si chiede una card sola.

drop function if exists public.get_activity_feed(text, uuid, timestamptz, uuid, integer);

create or replace function public.get_activity_feed(
  p_scope       text default 'following',
  p_user        uuid default null,
  p_before      timestamptz default null,
  p_before_id   uuid default null,
  p_limit       integer default 20,
  p_activity_id uuid default null
)
returns table(
  activity_id uuid,
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  activity_type text,
  media_type text,
  tmdb_id integer,
  episode_count integer,
  rating smallint,
  review_id uuid,
  review_content text,
  contains_spoilers boolean,
  list_id uuid,
  list_name text,
  list_cover_poster_paths text[],
  title text,
  poster_path text,
  occurred_at timestamptz,
  like_count integer,
  comment_count integer,
  liked_by_me boolean
)
language sql
stable
security definer
set search_path = public
as $$
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
    -- Nascosta è nascosta anche per chi l'ha nascosta: l'ha tolta dal feed, non messa in una
    -- stanza privata dove continuare a rivederla.
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
    -- La card singola (deep link da notifica): l'id sostituisce scope e cursore, il gate no.
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

comment on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer, uuid) is
  'Social feed M3: come la M2 (conteggi veri, velo sulle review a >=3 report) più le card '
  'nascoste escluse (activities.hidden_at) e p_activity_id per la singola card del deep link, '
  'che salta scope e cursore ma non il gate.';

revoke all on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer, uuid) from public;
revoke all on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer, uuid) from anon;
revoke all on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer, uuid) from authenticated;
grant execute on function public.get_activity_feed(text, uuid, timestamptz, uuid, integer, uuid) to authenticated;
