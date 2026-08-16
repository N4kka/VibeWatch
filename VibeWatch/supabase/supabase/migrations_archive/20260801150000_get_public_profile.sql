-- SPEC v3 §9.3 — il profilo pubblico come lo vede un altro utente.
--
-- L'header di §9.3 vuole follower/following, ma la RLS di `user_follows` mostra al chiamante solo
-- le righe di cui e' uno dei due capi: i contatori di un profilo altrui non si possono sommare dal
-- client, per costruzione. Come per `search_users`: `security definer`, identita' da `auth.uid()`,
-- mai da un parametro.
--
-- **Un profilo bloccato — in qualunque verso — risponde `found: false`, identico a un profilo
-- inesistente.** Distinguere "non esiste" da "ti ha bloccato" sarebbe dire a chi e' stato
-- bloccato che lo e' stato: l'informazione che il blocco esiste e' essa stessa privata. Stessa
-- ragione per cui `search_users` esclude senza spiegare.
--
-- I dati anagrafici passano da `public_profiles`, la sola superficie pubblica: un profilo
-- privato, cancellato o senza username e' `found: false` senza codice in piu'.
create or replace function public.get_public_profile(p_username text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
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
                             and f.followee_id = (select auth.uid()) and f.deleted_at is null))
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

comment on function public.get_public_profile(text) is
  'SPEC v3 §9.3: profilo pubblico con contatori e relazione col chiamante. Bloccato in un verso '
  'qualunque = found:false, indistinguibile da inesistente: che il blocco esista e'' privato.';

revoke all on function public.get_public_profile(text) from public;
revoke all on function public.get_public_profile(text) from anon;
revoke all on function public.get_public_profile(text) from authenticated;
grant execute on function public.get_public_profile(text) to authenticated;
