# Phase 2: Security Hardening - Context

**Gathered:** 2026-03-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Remove the Cerebras API key from the app binary by routing all CerebrasService calls through a new Supabase Edge Function proxy. Migrate auth session token storage from unencrypted UserDefaults to iOS Keychain with silent in-place migration for existing users. No new user-visible features.

</domain>

<decisions>
## Implementation Decisions

### Edge Function — Auth and Logging
- Require Supabase JWT auth on every call to the proxy Edge Function — no unauthenticated calls permitted
- Edge Function logs token usage to Supabase via the existing `log_ai_token_usage` RPC (same as the client does today) — keeps quota tracking authoritative
- Background jobs (CerebrasBackendJobManager, CerebrasBackendBackgroundScheduler) silently skip if there is no active user session — best-effort, no retry queue needed

### Edge Function — Design
- Passthrough proxy: forward the full CerebrasChatRequest JSON body as-is to Cerebras and return the raw response — CerebrasService only changes the destination URL, not the request shape
- One Edge Function covers all callers (chat, recommendations, embeddings, content enhancement, clip metadata, behavior analysis) — no mixed path

### Config Cleanup
- Remove `Config.cerebrasAPIKey` from `Config.swift` entirely — no empty string fallback
- Remove `CEREBRAS_API_KEY` from `Secrets.xcconfig` and `Secrets.xcconfig.template`
- Any remaining reference to `Config.cerebrasAPIKey` must cause a compile error to force complete cleanup

### Keychain Implementation
- Use `supabase-swift` 2.39.0's `LocalStorage` protocol: implement a `KeychainStorage: LocalStorage` adapter and pass it to `SupabaseClient` init — no custom Keychain wrapper library needed
- Move all auth state to Keychain: both the SDK session (via LocalStorage) and the manual cache (`auth_cached_user`, `auth_cached_is_authenticated`) that AuthService writes manually
- Keychain accessibility: `kSecAttrAccessibleAfterFirstUnlock` — tokens accessible after first device unlock post-reboot, supports background sync tasks

### Migration
- On first launch after update: read existing UserDefaults token, write to Keychain
- If Keychain write succeeds: immediately clear `auth_cached_user` and `auth_cached_is_authenticated` from UserDefaults — no stale unencrypted auth data remains
- If Keychain write fails: force re-login — clear UserDefaults cache and sign user out; next sign-in writes directly to Keychain

### Claude's Discretion
- Keychain service name / account key naming
- Edge Function error response codes and body shape
- Migration detection mechanism (e.g., a one-time migration flag in UserDefaults or presence of old key)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `supabase/functions/revenuecat-webhook/index.ts`: Pattern for Edge Functions — uses `Deno.env.get(...)` for secrets, `createClient` with service role key, returns `new Response(...)`
- `AuthService.saveCachedAuthState()` / `loadCachedAuthState()`: These are the two methods to update for the Keychain migration
- `AuthService.clearCachedAuthState()`: Also needs to clear Keychain on sign-out

### Established Patterns
- Existing Edge Functions: Deno, `https://deno.land/std@0.131.0/http/server.ts`, secrets via `Deno.env.get`
- `Config.swift`: All API keys come from xcconfig → Info.plist → Config struct properties; removal means deleting the property and the xcconfig entry
- `CerebrasService.generateText(...)` at lines 282 and 496: Both add `Bearer Config.cerebrasAPIKey` header — both need to point at the Edge Function URL instead (URL from Config or hardcoded supabaseFunctionsBaseURL pattern from AuthService)

### Integration Points
- `CerebrasService` → new Edge Function URL (replacing `https://api.cerebras.ai/v1/chat/completions`)
- Edge Function → Cerebras (server-side, key never leaves server)
- `AuthService.setupClient()`: Where `SupabaseClient` is initialized — `KeychainStorage` adapter passed here as `localStorage:` parameter
- `AuthService.saveCachedAuthState()` / `loadCachedAuthState()` / `clearCachedAuthState()`: Replace `UserDefaults` calls with Keychain reads/writes for the manual cache
- Migration runs in `AuthService.init()` or `loadCachedAuthState()` on first launch

</code_context>

<specifics>
## Specific Ideas

- No specific implementation references — straightforward security hardening with standard iOS Keychain and Supabase Edge Function patterns

</specifics>

<deferred>
## Deferred Ideas

- None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-security-hardening*
*Context gathered: 2026-03-06*
