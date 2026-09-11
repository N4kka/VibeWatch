-- Un token morto deve poter diventare NULL.
--
-- `process-notifications` risponde a un UNREGISTERED di FCM con
-- `update user_devices set fcm_token = null`, che e' il modo in cui distingue
-- "questo utente non ha mai registrato un dispositivo" (nessuna riga: l'email e'
-- l'unico canale) da "il dispositivo c'era e non c'e' piu'" (riga con token nullo:
-- il silenzio e' la risposta giusta). Ma la colonna era NOT NULL e l'esito di
-- quell'update non viene letto: la pulizia falliva in silenzio da sempre, i token
-- morti restavano vivi nella tabella e ogni invio ci sbatteva di nuovo contro.
--
-- Sul web conta molto di piu' che su iOS: un token del browser muore ogni volta che
-- si svuota la cache del sito o si revoca il permesso dalle impostazioni, cioe'
-- spesso, mentre quello di un'app installata dura quanto l'installazione.
--
-- Nessun dato si perde: la colonna si allarga, non si stringe. Le due UNIQUE
-- reggono i NULL (in Postgres due NULL non sono uguali fra loro), e
-- `register_user_device` continua a fare ON CONFLICT (user_id, fcm_token) sulle
-- righe vive, che sono le uniche con cui puo' entrare in conflitto.
alter table public.user_devices alter column fcm_token drop not null;

comment on column public.user_devices.fcm_token is
  'Token FCM del dispositivo. NULL = token revocato/scaduto, riga tenuta apposta per '
  'distinguere "dispositivo morto" da "mai registrato" nel fallback via email.';
