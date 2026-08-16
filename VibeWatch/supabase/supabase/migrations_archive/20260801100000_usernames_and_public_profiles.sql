-- SPEC v3 §3.6 / §3.7 — lo username, la superficie pubblica del profilo, e niente di piu'.
--
-- **Il punto che oggi blocca tutto.** `profiles` e' `select` solo per il proprietario, quindi
-- nessun utente vede niente di nessun altro: ricerca utenti, profilo altrui e autore di una lista
-- pubblica sono tutti impossibili, non difficili. §3.7 e' esplicito su come si apre — **non**
-- rilassando la policy su `profiles`, ma con una vista che espone il minimo. `profiles` contiene
-- `email`, `fcm_token`, `has_billing_issue`, `is_on_trial`: allargare li' significherebbe
-- pubblicare l'indirizzo email e lo stato di fatturazione di 314 persone.
--
-- **Cosa NON fa questa migration.** Non assegna gli username agli utenti esistenti: la colonna
-- nasce nullable e vuota. Il riempimento tocca 314 record di persone vere, si fa a parte e si
-- guarda prima (`suggest_username` esiste apposta per poterlo simulare con una SELECT).

-- ---------------------------------------------------------------------------- estensioni
-- `citext` per l'unicita' senza distinzione di maiuscole: `Mario` e `mario` devono collidere,
-- altrimenti l'impersonificazione e' banale. `pg_trgm` serve alla ricerca di §3.7.
create extension if not exists citext with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------- profiles
alter table public.profiles
  add column if not exists username             extensions.citext,
  add column if not exists bio                  text,
  add column if not exists is_profile_public    boolean not null default true,
  add column if not exists username_changed_at  timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_username_format') then
    -- Minuscole, cifre e underscore, 3-20. Il check ammette il null: gli utenti esistenti non
    -- hanno uno username e non si puo' inventarlo in un vincolo.
    alter table public.profiles add constraint profiles_username_format
      check (username is null or username ~ '^[a-z0-9_]{3,20}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_bio_length') then
    alter table public.profiles add constraint profiles_bio_length
      check (bio is null or length(bio) <= 200);
  end if;
end $$;

-- Unicita' su un indice parziale e non su una colonna `unique`: i profili cancellati
-- (`deleted_at`) non devono tenere occupato uno username per sempre.
create unique index if not exists profiles_username_unique
  on public.profiles (username) where username is not null and deleted_at is null;

-- La ricerca di §3.7. `gin_trgm_ops` su entrambe le colonne cercabili.
create index if not exists profiles_username_trgm
  on public.profiles using gin (username extensions.gin_trgm_ops);
create index if not exists profiles_display_name_trgm
  on public.profiles using gin (display_name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------- username riservati
create table if not exists public.username_reserved (name extensions.citext primary key);

insert into public.username_reserved (name) values
  ('admin'), ('administrator'), ('support'), ('help'), ('vibewatch'), ('vibe'), ('api'), ('www'),
  ('mail'), ('email'), ('settings'), ('setting'), ('about'), ('login'), ('signin'), ('signup'),
  ('register'), ('logout'), ('privacy'), ('terms'), ('legal'), ('security'), ('root'), ('system'),
  ('official'), ('staff'), ('team'), ('moderator'), ('mod'), ('null'), ('undefined'), ('me'),
  ('you'), ('user'), ('users'), ('profile'), ('profiles'), ('list'), ('lists'), ('clip'),
  ('clips'), ('search'), ('explore'), ('discover'), ('tracking'), ('feed'), ('home'), ('app'),
  ('ios'), ('android'), ('web'), ('blog'), ('news'), ('press'), ('jobs'), ('careers'),
  ('contact'), ('billing'), ('payment'), ('pro'), ('premium'), ('free'), ('test'), ('demo')
on conflict (name) do nothing;

alter table public.username_reserved enable row level security;
-- Nessuna policy: il client non deve leggere l'elenco (dice cosa esiste lato prodotto) ne'
-- scriverlo. Chi ne ha bisogno e' `username_available`, che e' `security definer`.

-- ------------------------------------------------------------------- generazione e verifica

-- Da un nome qualsiasi allo scheletro di uno username valido. **Immutable e pura**: e' la stessa
-- regola che deve valere nel backfill, alla registrazione e in un eventuale suggerimento nella UI,
-- e averne tre copie che divergono e' il modo documentato di sbagliare in questo progetto.
create or replace function public.username_seed(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(
    -- Il taglio a 20 va **dopo** la ripulitura e prima dell'ultima potatura, altrimenti un nome
    -- lungo puo' finire con un underscore appeso: `substring` non sa dove sta un separatore.
    btrim(
      substring(
        btrim(
          -- Spazi, punti e trattini diventano underscore invece di sparire: "Anna Rossi" ->
          -- "anna_rossi", non "annarossi". Poi si toglie tutto cio' che non e' ammesso, e si
          -- collassano gli underscore consecutivi che ne risultano.
          regexp_replace(
            regexp_replace(
              regexp_replace(lower(coalesce(p_name, '')), '[\s.\-]+', '_', 'g'),
              '[^a-z0-9_]', '', 'g'),
            '_+', '_', 'g'),
          -- Un nome scritto con uno spazio in fondo — succede, `"carebare "` sta in produzione —
          -- darebbe `carebare_`. Un underscore agli estremi non lo ha voluto nessuno.
          '_')
        from 1 for 20),
      '_'),
    '');
$$;

comment on function public.username_seed(text) is
  'SPEC v3 §3.6: da un display name allo scheletro di uno username. Unica regola, tre chiamanti.';

-- Uno username e' disponibile? Riservato, gia' preso o malformato -> no.
--
-- `security definer` perche' deve leggere `username_reserved` e gli username altrui, che il
-- client non puo' vedere. Non prende nessuna identita' come parametro: risponde su una stringa e
-- basta, quindi non c'e' niente da confondere con l'utente sbagliato.
create or replace function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_username is not null
     and p_username ~ '^[a-z0-9_]{3,20}$'
     and not exists (select 1 from public.username_reserved r where r.name = p_username::extensions.citext)
     and not exists (
           select 1 from public.profiles p
            where p.username = p_username::extensions.citext and p.deleted_at is null);
$$;

-- Il primo username libero a partire da un nome. Suffisso numerico in caso di collisione, come
-- chiede §3.7.
--
-- **Non scrive niente**: restituisce una proposta. Cosi' il backfill si puo' simulare con una
-- SELECT prima di toccare 314 profili veri, ed e' esattamente cio' che e' stato fatto.
create or replace function public.suggest_username(p_name text, p_fallback text default null)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base   text := public.username_seed(p_name);
  v_try    text;
  v_suffix integer := 2;
begin
  -- Troppo corto (o vuoto): non si allunga il nome dell'utente con caratteri inventati, si passa
  -- al ripiego. "Jo" -> "jo1" sarebbe uno username che l'utente non riconosce come suo, e che
  -- oltretutto sembra scelto.
  --
  -- Il ripiego generico e' `user`, che sta di proposito **anche fra i riservati**: cosi' nessuno
  -- si ritrova `@user` nudo, e chi ci finisce prende `user2`, `user3`... Non e' un bel nome ed e'
  -- giusto che non lo sia — §3.7 vuole la conferma al primo accesso, e uno username brutto e' cio'
  -- che fa venire voglia di cambiarlo.
  --
  -- **`p_fallback` non deve mai essere l'email, nemmeno la sola parte locale.** Sembrava la scelta
  -- ovvia e sui dati veri e' una fuga: dei 18 profili che ci sarebbero ricaduti, 9 hanno un
  -- indirizzo `@privaterelay.appleid.com` — la parte locale e' il token di relay di Apple, e
  -- pubblicarlo come `@8xp9vsbgxm` ricostruisce un indirizzo contattabile — e 3 hanno un locale
  -- che e' un numero di telefono (`@qq.com`, `@139.com`). Tutta §3.7 esiste per tenere l'email
  -- fuori dalla superficie pubblica; farcela rientrare dalla porta di servizio del ripiego sarebbe
  -- stato il modo piu' silenzioso di annullarla.
  -- Il ripiego si prova quando lo scheletro e' **inutilizzabile**, non solo quando e' nullo:
  -- `"bz"` produce `bz`, che non e' null ma nemmeno valido, e senza questa distinzione un
  -- `coalesce` si fermerebbe li' senza mai guardare il ripiego. Sono 13 profili su 314.
  if v_base is null or length(v_base) < 3 then
    v_base := public.username_seed(p_fallback);
    if v_base is null or length(v_base) < 3 then v_base := 'user'; end if;
  end if;

  if public.username_available(v_base) then
    return v_base;
  end if;

  -- Il suffisso deve stare dentro i 20 caratteri: si accorcia la base, non si sfora il vincolo.
  loop
    v_try := substring(v_base from 1 for 20 - length(v_suffix::text)) || v_suffix::text;
    exit when public.username_available(v_try);
    v_suffix := v_suffix + 1;
    -- Con 314 utenti non ci si arriva mai; il tetto c'e' perche' un ciclo senza uscita in una
    -- funzione chiamata alla registrazione e' un modo di bloccare le registrazioni.
    if v_suffix > 9999 then
      return null;
    end if;
  end loop;

  return v_try;
end $$;

-- ------------------------------------------------------------------------ public_profiles
--
-- La superficie pubblica, e **solo** questa. Niente email, niente fcm_token, niente stato di
-- fatturazione. Tutte le feature sociali leggono da qui, mai da `profiles`.
--
-- `security_invoker = off` (il default) di proposito, al contrario delle viste del tracking: li'
-- la vista doveva ereditare la RLS del proprietario, qui deve **scavalcarla**, perche' il punto e'
-- far vedere a uno il profilo di un altro. Cio' che la rende sicura non e' la RLS ma il `where`:
-- solo profili non cancellati, pubblici, e con uno username assegnato.
create or replace view public.public_profiles as
select id, username, display_name, avatar_url, bio, created_at
from public.profiles
where deleted_at is null
  and is_profile_public
  and username is not null;

comment on view public.public_profiles is
  'SPEC v3 §3.7: la sola superficie pubblica del profilo. Niente email ne'' campi di billing.';

revoke all on public.public_profiles from public;
grant select on public.public_profiles to anon, authenticated;

-- ------------------------------------------------------------- cosa il client puo' scrivere
--
-- `profiles_update_own` esiste gia' e permette al proprietario di aggiornare la propria riga —
-- **tutta**, comprese `is_founding_member` e `is_on_trial`. Non e' materia di questa migration,
-- ma le colonne nuove non devono peggiorare la situazione: `username_changed_at` lo scrive un
-- trigger, non il client, altrimenti il limite di frequenza sarebbe una decorazione.
create or replace function public.tg_profiles_username_changed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.username is distinct from old.username then
    new.username_changed_at := now();
  else
    new.username_changed_at := old.username_changed_at;
  end if;
  return new;
end $$;

drop trigger if exists profiles_username_changed on public.profiles;
create trigger profiles_username_changed
  before update on public.profiles
  for each row execute function public.tg_profiles_username_changed();

-- ------------------------------------------------------------------------------- permessi
--
-- I revoke vanno a PUBLIC **e** ai due ruoli client: su Supabase un `alter default privileges`
-- concede EXECUTE ad anon/authenticated in modo esplicito, e revocare al solo PUBLIC lascia i
-- grant espliciti al loro posto. Il controllo che vale e' `proacl`.
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.username_seed(text)',
    'public.username_available(text)',
    'public.suggest_username(text, text)',
    'public.tg_profiles_username_changed()'
  ] loop
    execute format('revoke all on function %s from public', fn);
    execute format('revoke all on function %s from anon', fn);
    execute format('revoke all on function %s from authenticated', fn);
  end loop;
end $$;

-- `username_available` e' l'unica che il client deve poter chiamare: serve alla schermata di
-- scelta dello username per dire "libero" mentre si digita. Non rivela di chi sia uno username
-- occupato, solo che lo e'.
grant execute on function public.username_available(text) to authenticated;
