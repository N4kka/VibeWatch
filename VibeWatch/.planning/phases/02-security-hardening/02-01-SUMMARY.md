---
phase: 02-security-hardening
plan: "01"
subsystem: api
tags: [supabase, edge-function, deno, jwt, cerebras, proxy, ios, swift]

requires:
  - phase: 01-critical-bug-fixes
    provides: stable app build baseline

provides:
  - Supabase Edge Function cerebras-proxy deployed and active (JWT auth + Cerebras passthrough)
  - CEREBRAS_API_KEY stored as server-side secret only — removed from app bundle
  - CerebrasService routes all AI calls through proxy using Supabase JWT
  - Background jobs guard for active session before attempting AI calls

affects:
  - 02-02 (Keychain migration — builds on same auth/session infrastructure)

tech-stack:
  added:
    - Supabase Edge Function (cerebras-proxy) — Deno runtime, @supabase/supabase-js@2 via esm.sh
  patterns:
    - Passthrough proxy with per-request JWT verification via supabase.auth.getUser(token)
    - Two-client pattern: anon client for JWT verify, service-role admin client for RPC logging
    - Dynamic baseURL from Config.supabaseURL — host substitution .supabase.co → .functions.supabase.co
    - Session guard pattern in background jobs — silent skip, no retry queue

key-files:
  created:
    - supabase/functions/cerebras-proxy/index.ts
  modified:
    - VibeWatchApp/Core/Network/CerebrasService.swift
    - VibeWatchApp/Core/Services/CerebrasBackendJobManager.swift
    - VibeWatchApp/Core/Network/Config.swift (gitignored — cerebrasAPIKey property removed)
    - VibeWatchApp/Config/Secrets.xcconfig (gitignored — CEREBRAS_API_KEY line removed)
    - VibeWatchApp/Config/Secrets.xcconfig.template (gitignored — CEREBRAS_API_KEY line removed)

key-decisions:
  - "cerebras-proxy deployed with --no-verify-jwt to enable per-request client JWT verification"
  - "Two Supabase clients in Edge Function: anon (JWT verify) + service role (log_ai_token_usage RPC) per RESEARCH.md Pitfall 2"
  - "Config.cerebrasAPIKey removed entirely with no empty-string fallback — compile error enforces cleanup"
  - "Session guard in processPendingJobs() uses silent skip (no retry) per locked user decision"
  - "SUPABASE_SERVICE_ROLE_KEY secret already present in Supabase project as SERVICE_ROLE_KEY alias — log_ai_token_usage RPC uses SUPABASE_SERVICE_ROLE_KEY env var"

patterns-established:
  - "Edge Function JWT auth: require Authorization header -> getUser(token) -> 401 on failure"
  - "Background job session guard: try? await AuthService.shared.client?.auth.session, return on empty token"

requirements-completed: [SEC-01]

duration: 9min
completed: 2026-03-06
---

# Phase 02 Plan 01: Cerebras Proxy Edge Function Summary

**Supabase Edge Function cerebras-proxy deployed with JWT auth and token usage logging — Cerebras API key removed from app binary, CerebrasService routes through proxy using Supabase JWT**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-06T09:32:49Z
- **Completed:** 2026-03-06T09:41:49Z
- **Tasks:** 2
- **Files modified:** 5 (3 gitignored)

## Accomplishments

- cerebras-proxy Edge Function deployed to Supabase (ACTIVE) — JWT auth gates every call, returns 401 on missing/invalid token; smoke test confirmed 401 behavior
- CEREBRAS_API_KEY secret set via `supabase secrets set` — removed from Secrets.xcconfig, Secrets.xcconfig.template, and Config.swift; key rotation now server-side without app update
- CerebrasService.swift updated: baseURL points to Edge Function URL, both chat() and generateResponse() use Supabase JWT session token — BUILD SUCCEEDED with zero cerebrasAPIKey references
- CerebrasBackendJobManager.processPendingJobs() guards for active session, skips silently when none

## Task Commits

1. **Task 1: Create cerebras-proxy Edge Function** - `a01f209` (feat)
2. **Task 2: Remove Config.cerebrasAPIKey and update CerebrasService** - `96bda44` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `supabase/functions/cerebras-proxy/index.ts` — New Edge Function: JWT auth via supabase.auth.getUser, Cerebras passthrough, token usage logging via adminSupabase.rpc
- `VibeWatchApp/Core/Network/CerebrasService.swift` — baseURL changed to Edge Function URL, both Auth header sites updated to use Supabase JWT session token
- `VibeWatchApp/Core/Services/CerebrasBackendJobManager.swift` — Session guard added at top of processPendingJobs()
- `VibeWatchApp/Core/Network/Config.swift` (gitignored) — cerebrasAPIKey property removed
- `VibeWatchApp/Config/Secrets.xcconfig` (gitignored) — CEREBRAS_API_KEY line removed
- `VibeWatchApp/Config/Secrets.xcconfig.template` (gitignored) — CEREBRAS_API_KEY placeholder removed

## Decisions Made

- Deployed with `--no-verify-jwt` to allow the function to perform its own JWT verification via per-request Supabase client — required for the two-client pattern
- Two clients in Edge Function: anon key client for getUser(token) verification, separate service-role client for log_ai_token_usage RPC — avoids RLS violations on the RPC (Pitfall 2 from RESEARCH.md)
- Config.cerebrasAPIKey removed with no fallback — any remaining reference is a compile error, enforcing complete cleanup

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

- xcodebuild initially failed with "device not found" for `platform=iOS Simulator,name=iPhone 16` (Xcode 26 simulator names changed). Resolved by using the simulator UDID directly (`id=601C4430-6213-49E3-8A4D-3564B2B57E2A`).
- First build attempt after simulator fix failed with "database is locked" (Xcode was open with a concurrent build). Resolved with a brief wait.
- Config.swift and Secrets.xcconfig are gitignored by `.gitignore` — changes made locally, committed via tracked files only (CerebrasService.swift, CerebrasBackendJobManager.swift). The gitignore intentionally keeps secrets out of version control.

## User Setup Required

None — CEREBRAS_API_KEY was set as a Supabase secret during execution. The Edge Function is deployed and active. No additional dashboard steps required.

## Next Phase Readiness

- SEC-01 complete. cerebras-proxy is live and the app binary contains no Cerebras API key reference.
- 02-02 (Keychain migration for auth tokens) can proceed independently — uses AuthService infrastructure, no dependency on this plan's deliverables.

---
*Phase: 02-security-hardening*
*Completed: 2026-03-06*

## Self-Check: PASSED

- supabase/functions/cerebras-proxy/index.ts: FOUND
- VibeWatchApp/Core/Network/CerebrasService.swift: FOUND
- .planning/phases/02-security-hardening/02-01-SUMMARY.md: FOUND
- Commit a01f209 (Task 1): FOUND
- Commit 96bda44 (Task 2): FOUND
