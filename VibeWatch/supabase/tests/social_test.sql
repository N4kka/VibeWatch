-- Blocco 8 di §12 — username, `public_profiles`, e i criteri 8 e 9 di §13.
--
-- Si esegue con supabase/tests/run.sh. Una asserzione fallita interrompe tutto.

\set ON_ERROR_STOP on
\set QUIET 1
\pset pager off
\pset tuples_only on
\pset footer off

begin;
set local timezone = 'UTC';

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@test'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'b@test'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'c@test'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'd@test');

insert into public.profiles (id, email, display_name, fcm_token, is_on_trial) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@test', 'Anna Rossi',  'token-a', true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'b@test', 'anna rossi',  'token-b', false),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'c@test', 'Jo',          'token-c', false),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'd@test', 'Zed',         'token-d', false);

\echo ''
\echo '=== §3.6 username_seed: una regola sola, tre chiamanti'

select t.eq(public.username_seed('Anna Rossi'), 'anna_rossi',
            'lo spazio diventa underscore, non sparisce');
select t.eq(public.username_seed('Anna.Rossi'), 'anna_rossi', 'idem il punto');
select t.eq(public.username_seed('Anna-Rossi'), 'anna_rossi', 'idem il trattino');
select t.eq(public.username_seed('Ànna Rossi!'), 'nna_rossi',
            'cio'' che non e'' ammesso si toglie, non si traslittera a caso');
select t.eq(public.username_seed('MARIO'), 'mario', 'minuscole');
select t.eq(public.username_seed('abcdefghijklmnopqrstuvwxyz'), 'abcdefghijklmnopqrst',
            'tagliato a 20, che e'' il massimo del vincolo');
select t.eq(length(public.username_seed('abcdefghijklmnopqrstuvwxyz')), 20, 'esattamente 20');
select t.eq(public.username_seed('a_very_long_display_name_indeed'), 'a_very_long_display',
            'e se il taglio cade su un separatore, quello non resta appeso');
select t.eq(public.username_seed('!!!'), null, 'niente di utilizzabile -> null, non stringa vuota');
select t.eq(public.username_seed(null), null, 'null -> null');
-- Trovati sui nomi veri in produzione, non immaginati: `"carebare "` con lo spazio in fondo
-- esiste, ed e' esattamente il genere di cosa che si vede solo guardando i dati.
select t.eq(public.username_seed('carebare '), 'carebare',
            'lo spazio in fondo non diventa un underscore appeso');
select t.eq(public.username_seed('  Anna   Rossi  '), 'anna_rossi',
            'ne'' gli spazi davanti, ne'' quelli doppi in mezzo');
select t.eq(public.username_seed('Anna - Rossi'), 'anna_rossi',
            'separatori consecutivi si collassano in uno');
select t.eq(public.username_seed('___'), null, 'solo separatori -> null, non una stringa di underscore');
select t.eq(public.username_seed('微光 渺渺'), null,
            'un nome non latino non e'' riducibile a [a-z0-9_]: si dichiara, non si storpia');
select t.is_true(length(public.username_seed('anna_rossi_e_un_nome_lunghissimo')) <= 20,
            'il taglio a 20 vale anche dopo la potatura');
select t.is_true(public.username_seed('anna_rossi_e_un_nome_lunghissimo') !~ '_$',
            'e il taglio non lascia un underscore in fondo');

\echo ''
\echo '=== §3.7 username_available'

select t.eq(public.username_available('anna_rossi'), true, 'libero');
select t.eq(public.username_available('admin'), false, 'riservato');
select t.eq(public.username_available('VibeWatch'), false,
            'i riservati sono citext: non basta cambiare le maiuscole');
select t.eq(public.username_available('ab'), false, 'troppo corto');
select t.eq(public.username_available('a_very_long_display_name'), false, 'troppo lungo');
select t.eq(public.username_available('Anna'), false, 'le maiuscole non sono ammesse dal formato');
select t.eq(public.username_available('anna rossi'), false, 'ne'' gli spazi');
select t.eq(public.username_available(null), false, 'null non e'' disponibile, e non esplode');

update public.profiles set username = 'anna_rossi'
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';

select t.eq(public.username_available('anna_rossi'), false, 'ora e'' preso');
select t.eq(public.username_available('ANNA_ROSSI'), false,
            'e lo e'' anche cambiando le maiuscole (citext): altrimenti impersonare e'' banale');

\echo ''
\echo '=== §3.7 suggest_username: suffisso numerico in caso di collisione'

select t.eq(public.suggest_username('Zed Zulu'), 'zed_zulu', 'nessuna collisione: il nome cosi'' com''e''');
select t.eq(public.suggest_username('Anna Rossi'), 'anna_rossi2', 'collisione -> suffisso');

update public.profiles set username = 'anna_rossi2'
 where id = 'aaaaaaaa-0000-0000-0000-000000000002';
select t.eq(public.suggest_username('Anna Rossi'), 'anna_rossi3', 'e il suffisso avanza');

select t.eq(public.suggest_username('admin'), 'admin2',
            'un nome riservato non blocca la registrazione, ne'' propone uno libero');

-- Il suffisso non deve sfondare i 20 caratteri: si accorcia la base. Il nome di prova occupa
-- tutti e 20 i caratteri **senza** finire su un separatore, altrimenti la potatura lascerebbe
-- spazio libero e il caso limite non verrebbe provato.
update public.profiles set username = 'abcdefghijklmnopqrst'
 where id = 'aaaaaaaa-0000-0000-0000-000000000003';
select t.eq(public.suggest_username('abcdefghijklmnopqrstuvwxyz'), 'abcdefghijklmnopqrs2',
            'il suffisso entra dentro i 20, accorciando la base');
select t.is_true(length(public.suggest_username('abcdefghijklmnopqrstuvwxyz')) <= 20,
            'e il risultato rispetta sempre il vincolo');
select t.eq(public.username_available(public.suggest_username('abcdefghijklmnopqrstuvwxyz')),
            true, 'e cio'' che propone e'' davvero libero');

-- Un nome inutilizzabile non diventa uno username inventato addosso all'utente.
--
-- `user2` e non `user`: il ripiego generico sta di proposito anche fra i riservati, cosi' nessuno
-- si ritrova `@user` nudo. Il nome brutto e' voluto — §3.7 chiede la conferma al primo accesso, e
-- uno username brutto e' cio' che fa venire voglia di cambiarlo.
select t.eq(public.suggest_username('Jo'), 'user2', 'troppo corto -> ripiego numerato');
select t.eq(public.suggest_username(null), 'user2', 'nessun nome -> idem');
select t.eq(public.suggest_username('!!!', 'mario_b'), 'mario_b',
            'ma un ripiego esplicito migliore vince');
-- Il ripiego NON deve essere l'email. Sui dati veri: 9 profili su 314 hanno un indirizzo
-- @privaterelay.appleid.com, e la parte locale e' il token di relay di Apple — `@8xp9vsbgxm`
-- ricostruisce un indirizzo contattabile. Altri 3 hanno un locale che e' un numero di telefono.
-- Il test non puo' impedire a un chiamante di passarla, ma fissa il caso che ci si aspetta.
select t.eq(public.suggest_username('bz', '8xp9vsbgxm'), '8xp9vsbgxm',
            'la funzione usa il ripiego che le si da'': la scelta di NON dargli l''email sta in chi chiama');
select t.eq(public.suggest_username('Jo', '!!!'), 'user2',
            'e un ripiego inutilizzabile ricade sul generico invece di esplodere');

\echo ''
\echo '=== §3.7 public_profiles espone il minimo'

update public.profiles set username = 'zed_zulu', bio = 'ciao'
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';

-- L'elenco delle colonne e' il test vero: e' l'unica cosa che impedisce a un `select *` distratto
-- di pubblicare l'email e lo stato di fatturazione di 314 persone.
select t.eq(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'public_profiles'),
  array['id','username','display_name','avatar_url','bio','created_at'],
  'la vista espone esattamente sei colonne, quelle di §3.7');

select t.eq((select count(*)::integer from information_schema.columns
              where table_schema = 'public' and table_name = 'public_profiles'
                and column_name in ('email','fcm_token','is_on_trial','deleted_at')), 0,
            'niente email, niente token push, niente stato di fatturazione');

-- Chi ci finisce dentro, e chi no.
select t.eq((select count(*)::integer from public.public_profiles), 4,
            'i quattro profili con username ci sono');

update public.profiles set is_profile_public = false
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';
select t.eq((select count(*)::integer from public.public_profiles
              where id = 'aaaaaaaa-0000-0000-0000-000000000004'), 0,
            'un profilo privato sparisce');

update public.profiles set is_profile_public = true, deleted_at = now()
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';
select t.eq((select count(*)::integer from public.public_profiles
              where id = 'aaaaaaaa-0000-0000-0000-000000000004'), 0,
            'e un profilo cancellato pure');

-- Uno username liberato da una cancellazione torna disponibile: l'indice e' parziale apposta.
select t.eq(public.username_available('zed_zulu'), true,
            'lo username di un profilo cancellato non resta occupato per sempre');

update public.profiles set deleted_at = null where id = 'aaaaaaaa-0000-0000-0000-000000000004';

\echo ''
\echo '=== §13 criterio 8: due utenti non possono avere lo stesso username'

select t.rejects($$
  update public.profiles set username = 'anna_rossi'
   where id = 'aaaaaaaa-0000-0000-0000-000000000004'
$$, 'lo stesso username, alla lettera');

-- Attenzione a cosa prova davvero: `ANNA_ROSSI` viene fermato dal **formato** (23514), non
-- dall'unicita', perche' le maiuscole non sono ammesse a monte. La difesa contro
-- l'impersonificazione per maiuscole sta un passo prima, in `username_available`, ed e' provata li'.
select t.rejects($$
  update public.profiles set username = 'ANNA_ROSSI'
   where id = 'aaaaaaaa-0000-0000-0000-000000000004'
$$, 'le maiuscole non arrivano nemmeno all''indice unico');

select t.rejects($$
  update public.profiles set username = 'Non Valido'
   where id = 'aaaaaaaa-0000-0000-0000-000000000004'
$$, 'il formato e'' un vincolo, non un suggerimento');

select t.rejects($$
  update public.profiles set bio = repeat('x', 201)
   where id = 'aaaaaaaa-0000-0000-0000-000000000004'
$$, 'la bio sta sotto i 200 caratteri (§3.6)');

\echo ''
\echo '=== il cambio di username lo data il server'

update public.profiles set username = 'zed_zulu_2'
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';
select t.is_true((select username_changed_at is not null from public.profiles
                   where id = 'aaaaaaaa-0000-0000-0000-000000000004'),
            'cambiare username scrive username_changed_at');

-- Un client che prova a datarla nel passato — per aggirare un limite di frequenza — non ci riesce.
update public.profiles
   set username = 'zed_zulu_3', username_changed_at = '2000-01-01'
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';
select t.is_true((select username_changed_at > now() - interval '1 minute' from public.profiles
                   where id = 'aaaaaaaa-0000-0000-0000-000000000004'),
            'e il valore mandato dal client viene ignorato: lo decide il trigger');

-- Cambiare altro non deve toccare la data. Si confronta col valore di prima e non con `now()`:
-- dentro una transazione `now()` e' l'istante di inizio, quindi "minore di now()" sarebbe falso
-- anche col trigger corretto. E' lo stesso genere di test che passa o fallisce per la ragione
-- sbagliata.
create temporary table prima as
  select username_changed_at from public.profiles
   where id = 'aaaaaaaa-0000-0000-0000-000000000004';

-- Il ramo "username invariato" **riscrive il vecchio valore**, quindi una UPDATE che prova a
-- rimettere `username_changed_at` a null non aggiorna niente e non lo dice. E' il motivo per cui
-- il backfill spegne il trigger invece di ripulire dopo: senza questa prova, quella UPDATE
-- sembrerebbe funzionare.
update public.profiles set username_changed_at = null
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';
select t.is_true((select username_changed_at is not null from public.profiles
                   where id = 'aaaaaaaa-0000-0000-0000-000000000004'),
            'rimettere la data a null senza cambiare username non funziona: il trigger la ripristina');

update public.profiles set display_name = 'Zed Zed'
 where id = 'aaaaaaaa-0000-0000-0000-000000000004';

select t.eq((select username_changed_at from public.profiles
              where id = 'aaaaaaaa-0000-0000-0000-000000000004'),
            (select username_changed_at from prima),
            'ma cambiare altro non tocca la data');

\echo ''
\echo '=== §13 criterio 9: anon legge public_profiles e non legge profiles'

-- Il conteggio atteso si calcola **prima** di cambiare ruolo: da `anon` la RLS di `profiles`
-- restituisce zero, quindi confrontare le due query li' dentro darebbe 0 = 0 e passerebbe sempre.
-- Un numero scritto a mano invece misurerebbe la storia di questo file, che sopra ha cambiato
-- piu' volte chi e' pubblico.
create temporary table attesi as
  select count(*) as n from public.profiles
   where deleted_at is null and is_profile_public and username is not null;
grant select on attesi to anon, authenticated;

set local role anon;

select t.eq((select count(*) from public.public_profiles), (select n from attesi),
            'un anonimo vede tutti e soli i profili pubblici con username');
select t.is_true((select count(*) > 0 from public.public_profiles),
            'e sono davvero piu'' di zero, altrimenti l''asserzione sopra e'' vuota');
select t.eq((select count(*)::integer from public.profiles), 0,
            'e non vede una riga di profiles: li'' ci sono le email');

-- Le funzioni: un anonimo non deve poter enumerare gli username altrui ne'' i riservati.
select t.eq(has_function_privilege('public.username_available(text)', 'execute'), false,
            'anon non puo'' nemmeno sondare la disponibilita'': e'' un oracolo su chi esiste');
select t.eq(has_function_privilege('public.suggest_username(text, text)', 'execute'), false,
            'ne'' farsi proporre uno username');
select t.eq(has_function_privilege('public.username_seed(text)', 'execute'), false,
            'ne'' chiamare la funzione di normalizzazione');

set local role authenticated;
set local request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';

select t.eq(has_function_privilege('public.username_available(text)', 'execute'), true,
            'un utente autenticato si: la schermata di scelta deve poter dire libero');
select t.eq(has_function_privilege('public.suggest_username(text, text)', 'execute'), false,
            'ma non farsi proporre nomi: e'' il backfill a usarla, non il client');
select t.eq((select count(*)::integer from public.profiles), 1,
            'e continua a vedere solo la propria riga di profiles');

reset role;

-- I revoke si leggono su `proacl`, non sul comando che si e' scritto: su Supabase un
-- `alter default privileges` concede EXECUTE ai due ruoli client in modo esplicito, e revocare
-- al solo PUBLIC li lascia al loro posto. E'' il difetto gia'' trovato su `import_touched_shows`.
select t.eq((select count(*)::integer from pg_proc p
              where p.proname in ('username_seed','suggest_username')
                and array_to_string(p.proacl, ',') like '%anon=X%'), 0,
            'nessuna delle due e'' eseguibile da anon (letto da proacl)');
select t.is_true((select array_to_string(p.proacl, ',') like '%authenticated=X%'
                    from pg_proc p where p.proname = 'username_available'),
            'username_available lo e'' da authenticated');

rollback;

\echo ''
\echo 'TUTTI I TEST PASSATI'
