-- SEC-007 / residuo DEP-009: la tabella di backup dell'incident notifiche del 2026-07-23.
-- Verificato prima del drop: tutte e 7 le righe esistono in public.notifications con lo stesso id;
-- differiscono solo per is_sent/sent_at/last_error (il backup e' pre-invio, il live e' is_sent=true).
-- Nessun dato unico va perso.
drop table if exists public.notifications_backup_20260723_spam;
