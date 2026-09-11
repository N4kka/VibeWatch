-- SPEC v3 §3.7 — assegna uno username agli utenti che c'erano prima che esistesse.
--
-- **Perche' e' una migration a parte.** Tocca 314 record di persone vere. Lo schema e le funzioni
-- stanno in `20260801100000`, che e' additivo e non cambia un dato; questa scrive. Tenerle
-- separate significa poter applicare la prima, **simulare** questa con una SELECT, guardare cosa
-- verrebbe fuori, e solo dopo eseguirla — che e' quello che e' stato fatto, ed e' l'unico motivo
-- per cui la fuga qui sotto e' stata vista prima di diventare permanente.
--
-- **Solo dal display name.** L'email sembrava il ripiego ovvio per chi ha un nome non riducibile a
-- `[a-z0-9_]`. Sui dati veri e' una fuga: dei 18 profili che ci sarebbero ricaduti, **9 hanno un
-- indirizzo `@privaterelay.appleid.com`** — la parte locale e' il token di relay di Apple, e
-- pubblicarla come `@8xp9vsbgxm` ricostruisce un indirizzo contattabile — e 3 hanno un locale che
-- e' un numero di telefono (`@qq.com`, `@139.com`). §3.7 esiste per tenere l'email fuori dalla
-- superficie pubblica: farcela rientrare dal ripiego sarebbe stato il modo piu' silenzioso di
-- annullarla.
--
-- **Chi non ha un nome derivabile resta senza username**, e sono 19. Non e' una rinuncia:
-- `public_profiles` filtra gia' `username is not null`, quindi restano semplicemente fuori dalla
-- ricerca finche' non ne scelgono uno — che §3.7 chiede comunque a tutti, al primo accesso. Un
-- `user7` assegnato d'ufficio sarebbe un handle che non significa niente per la persona che lo
-- porta, e che qualcun altro potrebbe leggere come un account di prova.
--
-- **In ordine di iscrizione.** Chi c'era prima prende il nome pulito, chi e' arrivato dopo prende
-- il suffisso. E' l'unica regola che si possa spiegare a voce a quattro persone che si chiamano
-- tutte "John Apple", e non dipende da un id casuale.

-- **Il trigger va spento per la durata del backfill**, e non e' una comodita'.
--
-- `profiles_username_changed` scriverebbe `username_changed_at = now()` su tutti e 295. E' vero
-- alla lettera e falso nella sostanza: quello username non l'ha scelto l'utente, gliel'abbiamo
-- messo noi. Se domani si aggiunge un limite di frequenza ("si cambia una volta ogni N giorni") —
-- ed e' il genere di regola che si aggiunge — quei 295 si troverebbero bloccati proprio sulla
-- conferma al primo accesso che §3.7 pretende.
--
-- Rimetterlo a null dopo, con una UPDATE, **non funziona**: il trigger e' `before update` e sul
-- ramo "username invariato" fa `new.username_changed_at := old.username_changed_at`, cioe'
-- riscrive il vecchio valore sopra il null. Sarebbe stata una UPDATE che non aggiorna niente e
-- non lo dice — il difetto tipico di questa sessione, questa volta trovato leggendo il trigger
-- che avevo scritto un'ora prima.
alter table public.profiles disable trigger profiles_username_changed;

do $$
declare
  r           record;
  v_nome      text;
  v_assegnati integer := 0;
  v_saltati   integer := 0;
begin
  for r in
    select id, display_name
      from public.profiles
     where deleted_at is null and username is null
     order by created_at nulls last, id
  loop
    if coalesce(length(public.username_seed(r.display_name)), 0) < 3 then
      v_saltati := v_saltati + 1;
      continue;
    end if;

    -- Nessun `p_fallback`: vedi sopra. Se il nome non basta, si lascia null.
    v_nome := public.suggest_username(r.display_name);
    if v_nome is null then
      v_saltati := v_saltati + 1;
      continue;
    end if;

    update public.profiles set username = v_nome where id = r.id;
    v_assegnati := v_assegnati + 1;
  end loop;

  raise notice 'username assegnati: %, lasciati null: %', v_assegnati, v_saltati;
end $$;

alter table public.profiles enable trigger profiles_username_changed;

-- Il primo cambio vero e' il primo cambio: dopo il backfill nessuno deve risultare "gia'
-- cambiato". Se questa asserzione salta, il trigger non era spento e il limite di frequenza
-- nascerebbe gia' scattato per 295 persone.
do $$
declare v_datati integer;
begin
  select count(*) into v_datati from public.profiles where username_changed_at is not null;
  if v_datati > 0 then
    raise exception 'backfill: % profili hanno username_changed_at valorizzato, doveva essere zero', v_datati;
  end if;
end $$;
