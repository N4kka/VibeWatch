-- SPEC v3 §3.7 — il budget per i tentativi di login con username.
--
-- La Edge Function `login-with-username` inoltra il grant password a GoTrue, quindi GoTrue vede
-- l'IP della funzione, non quello del client: il suo rate limiting sul brute force si indebolisce
-- passando da qui. Il tetto per IP lo tiene la funzione, con la macchina che c'e' gia'
-- (`api_proxy_try_spend`) — e questo CHECK enumera i provider, quindi l'aggiunta richiede una
-- migration (nota lasciata apposta nella migration di `tmdb`).
alter table public.api_proxy_budget drop constraint if exists api_proxy_budget_provider_check;
alter table public.api_proxy_budget add constraint api_proxy_budget_provider_check
  check (provider = any (array['youtube', 'streaming_availability', 'tmdb', 'auth_login']));
