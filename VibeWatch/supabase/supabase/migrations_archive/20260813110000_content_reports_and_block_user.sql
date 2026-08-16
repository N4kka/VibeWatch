-- Social feed M2 — la moderazione che i commenti esigono per andare live (OVERVIEW §7.5).
--
-- Le regole UGC di Apple chiedono tre cose: segnalare il contenuto, bloccare l'autore, un
-- canale di contatto. Le prime due nascono qui; i commenti del feed NON esistono nella UI
-- prima che questi attrezzi ci siano — è il vincolo di fase della M2.
--
-- **`content_reports` generalizza `list_reports`**, non la sostituisce: le liste hanno già la
-- loro tabella e la loro soglia in produzione, e migrarle non compra niente. Stessa soglia
-- ovunque (3 segnalatori distinti nascondono, il proprietario continua a vedere), stessa
-- idempotenza (un reporter conta una volta).
--
-- **`block_user` generalizza `block_list_owner`** e il trigger su `user_blocks` fa la parte
-- che nessun chiamante deve ricordarsi: un blocco in QUALUNQUE direzione tombstona i follow
-- fra i due — vale per la RPC nuova, per block_list_owner e per il ramo user_blocks di
-- apply_mutations, senza che nessuno dei tre debba saperlo.

create table if not exists public.content_reports (
  id            uuid primary key default gen_random_uuid(),
  reporter_id   uuid not null references auth.users (id) on delete cascade,
  content_type  text not null check (content_type in ('review','activity_comment')),
  content_id    uuid not null,
  reason        text,
  created_at    timestamptz not null default now(),
  unique (reporter_id, content_type, content_id)
);

comment on table public.content_reports is
  'Social feed M2: segnalazioni su review e commenti del feed. Un reporter conta una volta '
  '(unique); 3 distinti nascondono il contenuto ai lettori, mai al proprietario. Si scrive '
  'solo via report_content.';

create index if not exists content_reports_by_content
  on public.content_reports (content_type, content_id);

alter table public.content_reports enable row level security;

revoke all on public.content_reports from public;
revoke all on public.content_reports from anon;
revoke all on public.content_reports from authenticated;

-- ------------------------------------------------------------------------- report_content
--
-- Idempotente per costruzione (ON CONFLICT DO NOTHING): ri-segnalare non è un errore, è
-- ansia — e l'ansia non deve riempire sync_rejected_mutations né tornare 500. Il proprio
-- contenuto non si segnala: no-op silenzioso, non un oracolo.
create or replace function public.report_content(
  p_content_type text, p_content_id uuid, p_reason text default null)
returns void
language plpgsql
volatile
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
    return;  -- il proprio contenuto: niente da segnalare, niente da raccontare
  end if;

  insert into public.content_reports (reporter_id, content_type, content_id, reason)
  values (v_uid, p_content_type, p_content_id, nullif(btrim(coalesce(p_reason, '')), ''))
  on conflict (reporter_id, content_type, content_id) do nothing;
end $$;

-- ----------------------------------------------------------------------------- block_user
--
-- La riga di user_blocks si riusa come il re-follow (lapide che rivive): due blocchi dello
-- stesso utente sono lo stesso blocco. I follow li pota il trigger qui sotto.
create or replace function public.block_user(p_user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
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

-- ------------------------------------------------------- il blocco pota i follow, sempre
create or replace function public.tg_user_blocks_prune_follows()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return null;  -- lo sblocco non ricuce i follow: rifolloware e' una scelta, non un ripristino
  end if;
  update public.user_follows f
     set deleted_at = now(), synced_at = now()
   where f.deleted_at is null
     and ((f.follower_id = new.user_id and f.followee_id = new.blocked_user_id)
       or (f.follower_id = new.blocked_user_id and f.followee_id = new.user_id));
  return null;
end $$;

drop trigger if exists user_blocks_prune_follows on public.user_blocks;
create trigger user_blocks_prune_follows
  after insert or update on public.user_blocks
  for each row execute function public.tg_user_blocks_prune_follows();

revoke all on function public.report_content(text, uuid, text) from public;
revoke all on function public.report_content(text, uuid, text) from anon;
revoke all on function public.report_content(text, uuid, text) from authenticated;
grant execute on function public.report_content(text, uuid, text) to authenticated;

revoke all on function public.block_user(uuid) from public;
revoke all on function public.block_user(uuid) from anon;
revoke all on function public.block_user(uuid) from authenticated;
grant execute on function public.block_user(uuid) to authenticated;

revoke all on function public.tg_user_blocks_prune_follows() from public;
revoke all on function public.tg_user_blocks_prune_follows() from anon;
revoke all on function public.tg_user_blocks_prune_follows() from authenticated;
