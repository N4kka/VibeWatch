-- SPEC v3 §1.2 `DECISO` — via lo schema di tracking morto.
--
-- `tv_tracking` (16 colonne) e `tv_episode_progress` (7 colonne) esistono con schema completo,
-- RLS e policy, e hanno **0 righe, 0 scrittori, 0 lettori**: nessun riferimento nel codice Swift
-- (verificato), nessuna Edge Function le legge — `episode-radar` e `continue-watching-reminder`
-- leggono `list_items`. `v_tv_tracking_buckets` deriva un bucket testuale da una tabella vuota e
-- `get_tv_tracking_buckets()` non ha chiamanti.
--
-- Si droppano invece di riusarle perche' `tv_episode_progress` ha PK
-- (user, show, season, episode) e per costruzione non puo' rappresentare un rewatch, che e' il
-- requisito di §1.2. Al loro posto: `watch_events` + `tv_show_state`.
--
-- Il motivo per farlo ORA e non "dopo": lasciare schema morto accanto a schema vivo con nomi
-- simili e' gia' costato confusione una volta.

drop function if exists public.get_tv_tracking_buckets();
drop view if exists public.v_tv_tracking_buckets;
drop table if exists public.tv_episode_progress;
drop table if exists public.tv_tracking;
