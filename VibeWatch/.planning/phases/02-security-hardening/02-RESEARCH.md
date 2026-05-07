# Phase 2: Security Hardening - Research

**Researched:** 2026-03-06
**Domain:** iOS Keychain storage, Supabase Edge Functions (Deno), Cerebras API proxy
**Confidence:** HIGH

## Summary

Phase 2 has two independent tracks: (1) remove the Cerebras API key from the app binary by routing all `CerebrasService` calls through a new Supabase Edge Function passthrough proxy, and (2) migrate auth session token storage from unencrypted `UserDefaults` to iOS Keychain with silent migration for existing users.

**Track A (Edge Function proxy):** The existing codebase pattern is clear — Deno Edge Functions are already in use under `supabase/functions/`. The Cerebras proxy needs one new function that extracts the caller's JWT from the `Authorization` header, verifies it via `supabase.auth.getUser()`, forwards the raw `CerebrasChatRequest` JSON body to `https://api.cerebras.ai/v1/chat/completions` using the server-side `CEREBRAS_API_KEY` secret, logs token usage via the existing `log_ai_token_usage` RPC, and returns the raw response. `CerebrasService.swift` only needs its `baseURL` changed from the Cerebras endpoint to the Edge Function URL; the `Authorization` header becomes the Supabase JWT (obtained from `client.auth.session`), not the raw Cerebras key.

**Track B (Keychain migration):** supabase-swift 2.39.0 ships `KeychainLocalStorage` in `Auth/Storage/`. It conforms to `AuthLocalStorage` and is passed via `options.auth.storage` to `SupabaseClientOptions`. This handles the SDK session (refresh tokens) automatically. The manual cache (`auth_cached_user`, `auth_cached_is_authenticated`) in `AuthService` additionally needs direct Keychain calls using `Security` framework APIs. Migration runs once in `AuthService.init()`: read from `UserDefaults`, write to Keychain, clear `UserDefaults` on success or force re-login on failure.

**Primary recommendation:** Implement the two tracks as separate plans (Edge Function first, Keychain second) to isolate risks. No external libraries are needed for either track.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Require Supabase JWT auth on every call to the proxy Edge Function — no unauthenticated calls permitted
- Edge Function logs token usage to Supabase via the existing `log_ai_token_usage` RPC (same as the client does today) — keeps quota tracking authoritative
- Background jobs (CerebrasBackendJobManager, CerebrasBackendBackgroundScheduler) silently skip if there is no active user session — best-effort, no retry queue needed
- Passthrough proxy: forward the full CerebrasChatRequest JSON body as-is to Cerebras and return the raw response — CerebrasService only changes the destination URL, not the request shape
- One Edge Function covers all callers (chat, recommendations, embeddings, content enhancement, clip metadata, behavior analysis) — no mixed path
- Remove `Config.cerebrasAPIKey` from `Config.swift` entirely — no empty string fallback
- Remove `CEREBRAS_API_KEY` from `Secrets.xcconfig` and `Secrets.xcconfig.template`
- Any remaining reference to `Config.cerebrasAPIKey` must cause a compile error to force complete cleanup
- Use `supabase-swift` 2.39.0's `LocalStorage` protocol: implement a `KeychainStorage: LocalStorage` adapter and pass it to `SupabaseClient` init — no custom Keychain wrapper library needed
- Move all auth state to Keychain: both the SDK session (via LocalStorage) and the manual cache (`auth_cached_user`, `auth_cached_is_authenticated`) that AuthService writes manually
- Keychain accessibility: `kSecAttrAccessibleAfterFirstUnlock` — tokens accessible after first device unlock post-reboot, supports background sync tasks
- On first launch after update: read existing UserDefaults token, write to Keychain
- If Keychain write succeeds: immediately clear `auth_cached_user` and `auth_cached_is_authenticated` from UserDefaults — no stale unencrypted auth data remains
- If Keychain write fails: force re-login — clear UserDefaults cache and sign user out; next sign-in writes directly to Keychain

### Claude's Discretion
- Keychain service name / account key naming
- Edge Function error response codes and body shape
- Migration detection mechanism (e.g., a one-time migration flag in UserDefaults or presence of old key)

### Deferred Ideas (OUT OF SCOPE)
- None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SEC-01 | Cerebras API key never leaves the server — proxy all `CerebrasService` calls through a Supabase Edge Function; remove key from app bundle | Edge Function proxy pattern documented; `CerebrasService` call sites identified at lines 282 and 496; `Config.cerebrasAPIKey` removal path confirmed |
| SEC-02 | Auth session tokens stored in Keychain — migrate `AuthService` token persistence from `UserDefaults` to iOS Keychain | `KeychainLocalStorage` confirmed available in supabase-swift 2.39.0; `AuthLocalStorage` protocol documented; `saveCachedAuthState` / `loadCachedAuthState` / `clearCachedAuthState` method signatures confirmed |
</phase_requirements>

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| supabase-swift | 2.39.0 (project-pinned) | Auth, `SupabaseClient`, `KeychainLocalStorage` | Already the project's Supabase SDK; ships `KeychainLocalStorage` out of the box |
| Security.framework | System (iOS) | Direct Keychain reads/writes for manual cache | Apple-native; no additional dependency |
| Deno | Edge runtime | Supabase Edge Function runtime | All existing functions use Deno |
| `@supabase/supabase-js@2` | via esm.sh | Supabase client in Edge Function for JWT validation | Established pattern across all existing Edge Functions |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `https://deno.land/std@0.131.0/http/server.ts` | 0.131.0 | Deno HTTP server (serve()) | Matches existing Edge Function imports — keep consistent |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Built-in `KeychainLocalStorage` | Third-party library (e.g., KeychainAccess) | Decision is locked; built-in is sufficient and adds no dependency |
| `supabase.auth.getUser(token)` for JWT verify | `jose` library with JWKS | `getUser()` is simpler and sufficient; `jose` is for advanced key-rotation scenarios |

**No additional installations needed.** All dependencies are already present.

---

## Architecture Patterns

### Recommended Project Structure

```
supabase/functions/
└── cerebras-proxy/
    └── index.ts            # New Edge Function

VibeWatchApp/Core/Network/
├── CerebrasService.swift   # Change baseURL + Authorization header
└── Config.swift            # Remove cerebrasAPIKey property

VibeWatchApp/Core/Services/
├── AuthService.swift       # Add KeychainStorage adapter + migration
└── KeychainStorage.swift   # New file: AuthLocalStorage conformance

VibeWatchApp/Config/
└── Secrets.xcconfig        # Remove CEREBRAS_API_KEY line
```

### Pattern 1: Edge Function Passthrough Proxy

**What:** A Deno Edge Function that verifies the caller's Supabase JWT, forwards the raw request body to Cerebras, logs token usage, and returns the Cerebras response verbatim.

**When to use:** Any time an API key must remain server-side; the client sends its auth credential, not the upstream secret.

**Example:**
```typescript
// Source: established pattern from supabase/functions/revenuecat-webhook/index.ts
// + JWT auth pattern from https://supabase.com/docs/guides/functions/auth
import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const CEREBRAS_API_KEY = Deno.env.get('CEREBRAS_API_KEY') ?? ''
const CEREBRAS_ENDPOINT = 'https://api.cerebras.ai/v1/chat/completions'

serve(async (req) => {
  // 1. Require Authorization header
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' }
    })
  }

  // 2. Verify JWT — creates per-request client carrying the caller's token
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } }
  })
  const token = authHeader.replace('Bearer ', '')
  const { data: { user }, error: authError } = await supabase.auth.getUser(token)
  if (authError || !user) {
    return new Response(JSON.stringify({ error: 'Invalid or expired session' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' }
    })
  }

  // 3. Forward the raw request body to Cerebras unchanged
  const body = await req.text()
  const cerebrasResp = await fetch(CEREBRAS_ENDPOINT, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${CEREBRAS_API_KEY}`,
      'Content-Type': 'application/json'
    },
    body
  })

  // 4. Log token usage (best-effort — parse usage from Cerebras response)
  try {
    const respClone = cerebrasResp.clone()
    const respJson = await respClone.json()
    const tokensConsumed = respJson?.usage?.total_tokens ?? 0
    if (tokensConsumed > 0) {
      // Use service role key for RPC — separate admin client
      const adminSupabase = createClient(
        SUPABASE_URL,
        Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      )
      await adminSupabase.rpc('log_ai_token_usage', {
        p_user_id: user.id,
        p_tokens_consumed: tokensConsumed
      })
    }
  } catch (_) {
    // Non-fatal: quota tracking failure must not block AI response
  }

  // 5. Return raw Cerebras response
  const respBody = await cerebrasResp.text()
  return new Response(respBody, {
    status: cerebrasResp.status,
    headers: { 'Content-Type': 'application/json' }
  })
})
```

### Pattern 2: CerebrasService Client-Side Changes

**What:** Replace the Cerebras API endpoint URL and swap the Authorization header from the raw Cerebras key to the caller's Supabase JWT session token.

**When to use:** After the Edge Function is deployed and the Supabase function URL is known.

**Example:**
```swift
// Source: AuthService.swift supabaseFunctionsBaseURL pattern (lines 14-18)
// In CerebrasService.swift:
private let baseURL: String = {
    let base = Config.supabaseURL
    guard !base.isEmpty else { return "" }
    let host = base.replacingOccurrences(of: ".supabase.co", with: ".functions.supabase.co")
    return "\(host)/cerebras-proxy"
}()

// In both generateText variants, replace:
//   request.addValue("Bearer \(Config.cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
// With:
//   let session = try await AuthService.shared.client?.auth.session
//   guard let accessToken = session?.accessToken else { throw CerebrasError.unknown }
//   request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
```

### Pattern 3: KeychainLocalStorage Adapter for supabase-swift

**What:** Conform to `AuthLocalStorage` to store the SDK's session in Keychain instead of UserDefaults. Pass via `options.auth.storage` to `SupabaseClient`.

**When to use:** At `SupabaseClient` initialization time in `AuthService.setupClient()`.

**Note:** supabase-swift 2.39.0 ships `KeychainLocalStorage` as a concrete type. However, because the user decision specifies `kSecAttrAccessibleAfterFirstUnlock` (not the SDK default), a custom `KeychainStorage` adapter must be written that sets this explicit accessibility attribute.

**Example:**
```swift
// Source: supabase-swift AuthLocalStorage protocol (Sources/Auth/Storage/AuthLocalStorage.swift)
// Custom adapter to force kSecAttrAccessibleAfterFirstUnlock
import Security

final class KeychainStorage: AuthLocalStorage {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.vibewatch.auth") {
        self.service = service
    }

    func store(key: String, value: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        // Delete existing before insert (update pattern)
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
        return result as? Data
    }

    func remove(key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}

enum KeychainError: LocalizedError {
    case unhandledError(status: OSStatus)
    var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        }
    }
}

// In AuthService.setupClient():
var options = SupabaseClientOptions()
options.auth.storage = KeychainStorage()
client = SupabaseClient(supabaseURL: url, supabaseKey: supabaseAnonKey, options: options)
```

### Pattern 4: UserDefaults-to-Keychain Migration

**What:** One-time migration that runs in `AuthService.init()` before `setupClient()`. Reads legacy UserDefaults keys, writes to Keychain, clears UserDefaults on success, forces sign-out on failure.

**Migration detection:** Use UserDefaults presence of the old key (`auth_cached_user`) as the trigger — if the key exists, migration has not yet run. No separate "migration done" flag is needed because clearing the key is the completion signal.

**Example:**
```swift
// In AuthService.init(), called BEFORE loadCachedAuthState() and setupClient():
private func migrateUserDefaultsToKeychain() {
    let keychainStorage = KeychainStorage()
    var migrationFailed = false

    // Migrate auth_cached_user
    if let userData = userDefaults.data(forKey: cachedUserKey) {
        do {
            try keychainStorage.store(key: cachedUserKey, value: userData)
            userDefaults.removeObject(forKey: cachedUserKey)
        } catch {
            Logger.error("[Auth] Keychain migration failed for cached user: \(error)")
            migrationFailed = true
        }
    }

    // Migrate auth_cached_is_authenticated flag (stored as Data)
    let isAuth = userDefaults.bool(forKey: cachedAuthStateKey)
    if userDefaults.object(forKey: cachedAuthStateKey) != nil {
        let data = Data([isAuth ? 1 : 0])
        do {
            try keychainStorage.store(key: cachedAuthStateKey, value: data)
            userDefaults.removeObject(forKey: cachedAuthStateKey)
        } catch {
            Logger.error("[Auth] Keychain migration failed for auth state: \(error)")
            migrationFailed = true
        }
    }

    if migrationFailed {
        // Force re-login: clear both stores and let next sign-in write to Keychain
        userDefaults.removeObject(forKey: cachedUserKey)
        userDefaults.removeObject(forKey: cachedAuthStateKey)
        try? keychainStorage.remove(key: cachedUserKey)
        try? keychainStorage.remove(key: cachedAuthStateKey)
        Logger.warning("[Auth] Keychain migration failed — user will need to re-login")
    }
}
```

### Pattern 5: Background Job Session Guard (CerebrasBackendJobManager)

**What:** Before calling the Edge Function, check for a valid Supabase session. Skip silently if none present (no retry queue).

**Example:**
```swift
// In CerebrasBackendJobManager.processPendingJobs() or at job dispatch call sites:
guard let session = try? await AuthService.shared.client?.auth.session,
      !session.accessToken.isEmpty else {
    Logger.info("[CerebrasBackend] No active session — skipping background AI jobs")
    return
}
// Proceed with Edge Function calls
```

### Anti-Patterns to Avoid

- **Returning the raw Cerebras API key in any error response from the Edge Function:** Error bodies must never echo back the `CEREBRAS_API_KEY` value.
- **Storing `CEREBRAS_API_KEY` as an Edge Function secret without removing it from xcconfig:** Both must happen together; the client must not compile if the property still exists.
- **Using `kSecAttrAccessibleWhenUnlocked` instead of `kSecAttrAccessibleAfterFirstUnlock`:** Background tasks (BGProcessingTask) run when device may not have been recently unlocked by user. `AfterFirstUnlock` is required for background sync to read tokens.
- **Calling `SecItemDelete` without checking `errSecItemNotFound`:** Always treat `errSecItemNotFound` as success in delete operations.
- **Running migration after `setupClient()`:** SDK initialization reads storage; migration must happen before so the SDK sees Keychain, not UserDefaults.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SDK session storage in Keychain | Custom session serialization | `options.auth.storage = KeychainStorage()` | SDK manages session lifecycle, refresh token rotation, expiry — hand-rolling breaks all of that |
| JWT verification in Edge Function | Manual base64 decode + signature check | `supabase.auth.getUser(token)` | Handles token expiry, signature validation, revocation via Supabase Auth |
| Cerebras API key rotation | iOS xcconfig environment variable | Supabase Edge Function secret (`supabase secrets set`) | Secrets can be rotated server-side without shipping a new app version |
| Token usage logging | Client-side atomic counter | Server-side `log_ai_token_usage` RPC (already exists) | Client-side counters can be bypassed; RPC runs inside Postgres transaction |

**Key insight:** The Keychain and JWT verification problems both have well-tested platform solutions. Any hand-rolled alternative will miss edge cases (token refresh, concurrent Keychain access, clock skew in JWT validation).

---

## Common Pitfalls

### Pitfall 1: Two `Config.cerebrasAPIKey` References in CerebrasService

**What goes wrong:** Both `chat()` (line 282) and `generateResponse()` (line 496) use `Config.cerebrasAPIKey`. If only one is changed, the compile-error goal is not achieved.

**Why it happens:** `generateText()` calls `generateResponse()`, which contains one reference. `chat()` contains the other reference directly. They appear to be the same function path but are separate code paths.

**How to avoid:** Delete `Config.cerebrasAPIKey` from `Config.swift` first — this causes two compile errors that exactly identify both sites. Fix both, then the build succeeds.

**Warning signs:** Build succeeds with only one reference removed (the other is unreachable in some flows and may be silently missed).

### Pitfall 2: Edge Function Needs Two Supabase Clients

**What goes wrong:** Using the anon-key client to call `log_ai_token_usage` RPC fails because RLS on that function requires elevated permissions or the RPC expects the service role.

**Why it happens:** The per-request client inherits the caller's JWT and RLS restrictions. The `log_ai_token_usage` RPC needs elevated access to update another user's quota row.

**How to avoid:** Use two clients in the Edge Function: `supabase` (anon key + caller's Authorization header) for JWT verification, and `adminSupabase` (service role key from `SUPABASE_SERVICE_ROLE_KEY`) for the RPC call. Make the RPC call non-fatal (try/catch) so a logging failure never blocks the AI response.

**Warning signs:** 403 or RLS violation errors in Edge Function logs when calling `log_ai_token_usage`.

### Pitfall 3: Keychain Migration Order vs. SDK Init

**What goes wrong:** Calling `setupClient()` before `migrateUserDefaultsToKeychain()` means the SDK reads from UserDefaults (its default storage), writes its session back to UserDefaults, and the migration either misses the SDK session or double-migrates stale data.

**Why it happens:** `AuthService.init()` currently calls `loadCachedAuthState()` then `setupClient()`. Migration must be inserted before both.

**How to avoid:** Call `migrateUserDefaultsToKeychain()` as the very first line of `AuthService.init()`.

**Warning signs:** Users who were logged in get signed out on first launch even though migration "succeeded."

### Pitfall 4: `kSecAttrAccessibleAfterFirstUnlock` vs. Default

**What goes wrong:** The SDK's built-in `KeychainLocalStorage` uses a default accessibility attribute that may not be `kSecAttrAccessibleAfterFirstUnlock`. Using a different value for the manual cache creates inconsistency and may break background job token reads.

**Why it happens:** The built-in implementation's accessibility attribute is not explicitly documented in the SDK; research could not confirm it matches the requirement.

**How to avoid:** Write a custom `KeychainStorage` adapter (as decided) that explicitly sets `kSecAttrAccessibleAfterFirstUnlock`. This guarantees consistency for both SDK session and manual cache items.

**Warning signs:** Background tasks fail silently to authenticate when device has been rebooted but not yet unlocked by the user.

### Pitfall 5: Edge Function URL Not Available Offline

**What goes wrong:** `CerebrasService` points at the Edge Function URL. If the device is offline, all AI calls fail. The prior implementation also failed offline, so behavior is unchanged — but callers must handle the failure gracefully.

**Why it happens:** Moving from direct Cerebras API to proxy adds no offline regression. Background jobs already handle failure; interactive callers must also handle `CerebrasError.serverError`.

**How to avoid:** No change needed — existing `catch` blocks in callers already handle network errors. The background job session guard prevents unnecessary attempts.

### Pitfall 6: Supabase Edge Function Secrets Must Be Set Before Deploy

**What goes wrong:** Deploying `cerebras-proxy` before running `supabase secrets set CEREBRAS_API_KEY=...` causes the function to call Cerebras with an empty key, returning 401s.

**Why it happens:** Deno.env.get() returns undefined if the secret is not set; the function falls back to empty string.

**How to avoid:** Set secrets first, then deploy. Include the secret-setting step explicitly in the plan before the deploy step. Verify with `supabase secrets list`.

---

## Code Examples

### Verified: AuthLocalStorage Protocol Signature

```swift
// Source: https://github.com/supabase/supabase-swift (Sources/Auth/Storage/AuthLocalStorage.swift)
// Protocol name confirmed as AuthLocalStorage (not LocalStorage)
public protocol AuthLocalStorage: Sendable {
    func store(key: String, value: Data) throws
    func retrieve(key: String) throws -> Data?
    func remove(key: String) throws
}
```

### Verified: SupabaseClientOptions auth.storage

```swift
// Source: https://github.com/supabase/supabase-swift (Sources/Supabase/SupabaseClient.swift)
var options = SupabaseClientOptions()
options.auth.storage = myCustomStorage  // any AuthLocalStorage
let client = SupabaseClient(supabaseURL: url, supabaseKey: key, options: options)
```

### Verified: KeychainLocalStorage Init

```swift
// Source: supabase-swift Sources/Auth/Storage/KeychainLocalStorage.swift
// Conforms to AuthLocalStorage. Init parameters:
//   service: String? (defaults to "supabase.gotrue.swift")
//   accessGroup: String? (defaults to nil)
// NOTE: accessibility attribute is NOT configurable in the built-in type — reason custom adapter is required
let storage = KeychainLocalStorage(service: "com.vibewatch.auth")
```

### Verified: Edge Function JWT Pattern

```typescript
// Source: https://github.com/supabase/supabase/blob/master/examples/edge-functions/
//         supabase/functions/select-from-table-with-auth-rls/index.ts
// Pattern confirmed: per-request createClient with Authorization header forwarding
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  global: { headers: { Authorization: req.headers.get('Authorization')! } }
})
const { data: { user } } = await supabase.auth.getUser(token)
```

### Verified: Existing supabaseFunctionsBaseURL Pattern

```swift
// Source: AuthService.swift lines 14-18 — existing pattern for Edge Function base URL
private let supabaseFunctionsBaseURL: String = {
    let base = Config.supabaseURL
    guard !base.isEmpty else { return "" }
    return base.replacingOccurrences(of: ".supabase.co", with: ".functions.supabase.co")
}()
// Final Edge Function URL: "\(supabaseFunctionsBaseURL)/cerebras-proxy"
// Evaluates to: https://rqhxhkijzhqivljivirq.functions.supabase.co/cerebras-proxy
```

### Verified: Existing log_ai_token_usage RPC Signature

```swift
// Source: SupabaseClient.swift lines 820-828
struct LogUsageRequest: Encodable {
    let p_user_id: UUID
    let p_tokens_consumed: Int
}
// Called via: client.rpc("log_ai_token_usage", params: request).execute()
// In Edge Function (TypeScript): adminSupabase.rpc('log_ai_token_usage', { p_user_id: user.id, p_tokens_consumed: tokensConsumed })
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `Config.cerebrasAPIKey` embedded via xcconfig → Info.plist → binary | Server-side secret via `supabase secrets set` | This phase | Key no longer extractable from `.ipa` or `strings` dump |
| `UserDefaults` for auth token persistence | iOS Keychain with `kSecAttrAccessibleAfterFirstUnlock` | This phase | Tokens encrypted at rest; not readable by other apps or iTunes backup inspection |
| Client calls Cerebras directly | Client calls Supabase Edge Function proxy | This phase | Enables server-side key rotation without app update |

**Deprecated/outdated in this phase:**
- `Config.cerebrasAPIKey`: removed entirely — compile error if referenced post-migration
- `UserDefaults` keys `auth_cached_user` and `auth_cached_is_authenticated`: cleared during migration

---

## Open Questions

1. **KeychainLocalStorage built-in accessibility attribute**
   - What we know: The built-in `KeychainLocalStorage` uses an unspecified accessibility attribute (not documented in SDK source preview)
   - What's unclear: Whether `kSecAttrAccessibleAfterFirstUnlock` would match the default, making the custom adapter unnecessary for the SDK session part
   - Recommendation: Use the custom adapter for the full manual cache, and either use the built-in for the SDK session or use the custom adapter for both. Since the decision requires `kSecAttrAccessibleAfterFirstUnlock` explicitly, write one custom adapter and use it for everything — eliminates the uncertainty.

2. **`getClaims` vs. `getUser` for Edge Function JWT verification**
   - What we know: `getUser(token)` is the established, well-documented pattern; `getClaims(token)` is a newer API appearing in 2025 Supabase docs that uses `SB_PUBLISHABLE_KEY` (a new key type not yet widely available)
   - What's unclear: Whether the project's Supabase instance supports `getClaims` / `SB_PUBLISHABLE_KEY`
   - Recommendation: Use `getUser(token)` with `SUPABASE_ANON_KEY` — it is the proven pattern used across existing community examples and the official select-from-table-with-auth-rls example. LOW confidence on `getClaims` availability.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (Xcode native) |
| Config file | `VibeWatchAppTests/Info.plist` |
| Quick run command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing VibeWatchAppTests 2>&1 | tail -20` |
| Full suite command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -40` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SEC-01 | `Config.cerebrasAPIKey` does not compile | Build-time | `xcodebuild build -scheme VibeWatchApp 2>&1 | grep cerebrasAPIKey` | N/A (compile error IS the test) |
| SEC-01 | Edge Function correctly rejects unauthenticated requests | smoke / manual | Manual: `curl -X POST https://<url>/cerebras-proxy` without auth → expect 401 | ❌ Wave 0 |
| SEC-02 | `KeychainStorage` stores and retrieves data correctly | unit | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/KeychainStorageTests -destination 'platform=iOS Simulator,name=iPhone 16'` | ❌ Wave 0 |
| SEC-02 | Migration moves UserDefaults data to Keychain and clears UserDefaults | unit | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/AuthMigrationTests -destination 'platform=iOS Simulator,name=iPhone 16'` | ❌ Wave 0 |
| SEC-02 | Failed Keychain write triggers re-login (no stale data remains) | unit | included in `AuthMigrationTests` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `xcodebuild build -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5` (build check)
- **Per wave merge:** Full XCTest suite
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `VibeWatchAppTests/KeychainStorageTests.swift` — covers SEC-02 Keychain read/write/delete with mock Security framework or live Simulator Keychain
- [ ] `VibeWatchAppTests/AuthMigrationTests.swift` — covers SEC-02 migration success path, failure path, and idempotency
- [ ] Framework install: none needed (XCTest is built in)

---

## Sources

### Primary (HIGH confidence)
- `github.com/supabase/supabase-swift` (Sources/Auth/Storage/) — `AuthLocalStorage` protocol, `KeychainLocalStorage` struct, `SupabaseClientOptions.auth.storage` parameter
- `supabase.com/docs/guides/functions/auth` — Edge Function JWT verification pattern, `getUser(token)` approach
- `github.com/supabase/supabase/examples/edge-functions/select-from-table-with-auth-rls/index.ts` — per-request `createClient` with Authorization forwarding
- `VibeWatchApp/Core/Services/AuthService.swift` (read directly) — `loadCachedAuthState`, `saveCachedAuthState`, `clearCachedAuthState`, `setupClient`, `supabaseFunctionsBaseURL` pattern
- `VibeWatchApp/Core/Network/CerebrasService.swift` (read directly) — two `Config.cerebrasAPIKey` references at lines 282 and 496, `baseURL` field
- `VibeWatchApp/Core/Supabase/SupabaseClient.swift` (read directly) — `log_ai_token_usage` RPC signature, token logging pattern
- `supabase/functions/revenuecat-webhook/index.ts` (read directly) — existing Edge Function pattern (Deno, esm.sh, serve(), Deno.env.get())

### Secondary (MEDIUM confidence)
- `swiftpackageindex.com` — confirmed `KeychainLocalStorage` exists in supabase-swift 2.37.0 (closest available docs; 2.39.0 is project version, change is unlikely to break this API)
- `github.com/supabase/supabase-swift` `AuthClientConfiguration.swift` — `localStorage` parameter confirmed required in `AuthClient.Configuration.init`

### Tertiary (LOW confidence)
- `supabase.com/docs/guides/functions/auth` (2025 revision) — `getClaims` / `SB_PUBLISHABLE_KEY` new pattern; availability on this project's Supabase instance not verified; use `getUser` instead

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries are already project dependencies; APIs verified against source
- Architecture: HIGH — patterns derived from existing project code and official supabase-swift source
- Pitfalls: HIGH — identified from direct code inspection of call sites and ordering constraints
- Validation: MEDIUM — test file names are new (Wave 0 gaps); XCTest infrastructure confirmed present

**Research date:** 2026-03-06
**Valid until:** 2026-06-06 (supabase-swift API is stable; Supabase Edge Function patterns are stable; 90-day window is conservative)
