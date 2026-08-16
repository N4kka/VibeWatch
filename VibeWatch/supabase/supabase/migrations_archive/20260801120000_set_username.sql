-- SPEC v3 §3.7 — la scelta dello username, e il buco che il backfill ha lasciato aperto.
--
-- **Il buco.** `username_reserved` viene consultata da `username_available` e `suggest_username`,
-- cioe' dalle due funzioni che *propongono*. Niente la consulta quando si **scrive**: la policy
-- `profiles_update_own` permette al proprietario di aggiornare la propria riga, e il CHECK sul
-- formato non sa niente dei nomi riservati. Un client che fa un PATCH diretto su
-- `profiles.username = 'admin'` passa il formato, passa l'indice unico, e si prende `@admin`.
-- Una lista di riservati che si applica solo a chi la chiede gentilmente non e' una lista di
-- riservati.
--
-- Il posto giusto e' un trigger: un CHECK non puo' leggere un'altra tabella.

alter table public.profiles
  add column if not exists username_confirmed_at timestamptz;

comment on column public.profiles.username_confirmed_at is
  'Quando l''utente ha confermato o scelto il proprio username (§3.7). Null = assegnato dal '
  'backfill e mai visto da chi lo porta: e'' il segnale che fa comparire la schermata di scelta.';

-- ------------------------------------------------------------------ il trigger, allargato
create or replace function public.tg_profiles_username_changed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.username is distinct from old.username then
    -- Vale per **qualunque** scrittura, non solo per l'RPC: e' l'unico punto che un PATCH diretto
    -- non puo' scavalcare.
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

-- ------------------------------------------------------------------------- set_username
--
-- **Perche' un'RPC e non un PATCH.** Tre ragioni, tutte pratiche:
--
-- 1. il client non puo' leggere `username_reserved` (e non deve: l'elenco dice cose sul prodotto),
--    quindi da solo non sa distinguere "occupato" da "riservato" e mostrerebbe il messaggio
--    sbagliato;
-- 2. fra il controllo di disponibilita' e la scrittura c'e' una finestra in cui un altro utente
--    puo' prendere lo stesso nome. Qui la finestra non esiste: l'indice unico decide, e il
--    conflitto torna come esito e non come `23505` da interpretare a mano;
-- 3. `username_confirmed_at` si scrive qui e solo qui, insieme al nome.
--
-- Restituisce un esito, mai un'eccezione per i casi normali: "occupato" non e' un errore del
-- programma, e` una risposta.
create or replace function public.set_username(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_attuale extensions.citext;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  select username into v_attuale from public.profiles where id = v_uid;

  -- Confermare quello che si ha gia' e' il caso piu' comune dei 295 del backfill: non e' un
  -- cambio, non tocca `username_changed_at`, e non deve inciampare nell'indice unico contro se'
  -- stesso.
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
    -- Qualcuno l'ha preso fra il controllo e adesso. E' la corsa che l'RPC esiste per rendere
    -- innocua: si torna un esito, non un codice di errore da tradurre nel client.
    return jsonb_build_object('ok', false, 'reason', 'taken');
  end;

  return jsonb_build_object('ok', true, 'username', p_username, 'changed', true);
end $$;

comment on function public.set_username(text) is
  'SPEC v3 §3.7: sceglie o conferma il proprio username. Esito, non eccezione, sui casi normali.';

revoke all on function public.set_username(text) from public;
revoke all on function public.set_username(text) from anon;
revoke all on function public.set_username(text) from authenticated;
grant execute on function public.set_username(text) to authenticated;
