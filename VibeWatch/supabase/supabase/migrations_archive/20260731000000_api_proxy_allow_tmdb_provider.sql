-- `catalog-resolve` (§6) contabilizza il proprio budget sull'infrastruttura condivisa dei proxy
-- (`api_proxy_budget` + `api_proxy_try_spend`), ma il CHECK sul provider elencava solo i due
-- proxy che esistevano prima. Con `provider = 'tmdb'` l'insert dentro `api_proxy_try_spend`
-- violava il vincolo, la RPC tornava errore e `trySpend` falliva CHIUSO: la funzione rispondeva
-- `budget_exhausted: true` con zero chiamate verso TMDB.
--
-- Il fail-closed e' voluto — meglio non spendere quota che spenderla senza contarla — ed e'
-- esattamente cio' che ha reso il problema visibile al primo smoke test invece di lasciarlo
-- affiorare a import iniziato.
--
-- Nota per il prossimo proxy: questo CHECK enumera i provider, quindi ogni aggiunta richiede una
-- migration. Si paga una riga alla volta, ma tiene fuori i refusi ('tmbd') che altrimenti
-- creerebbero un budget separato e invisibile.

alter table public.api_proxy_budget drop constraint if exists api_proxy_budget_provider_check;
alter table public.api_proxy_budget add constraint api_proxy_budget_provider_check
  check (provider = any (array['youtube', 'streaming_availability', 'tmdb']));

-- Stessa estensione sulla cache: `catalog-resolve` oggi non la usa (la sua cache e'
-- `tvdb_tmdb_map`), ma tenere allineati i due vocabolari evita di ritrovarsi lo stesso
-- fallimento al primo uso di readCache/writeCache.
alter table public.api_proxy_cache drop constraint if exists api_proxy_cache_provider_check;
alter table public.api_proxy_cache add constraint api_proxy_cache_provider_check
  check (provider = any (array['youtube', 'streaming_availability', 'tmdb']));
