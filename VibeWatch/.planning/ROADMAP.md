# Roadmap: VibeWatch v1.0 Production

## Overview

This milestone stabilizes VibeWatch for production release. No new features — only the fixes, security hardening, and performance improvements required to ship confidently. Four phases address critical bugs first (data integrity and broken UX), then close security gaps (exposed API key, plaintext auth tokens), then enforce the sub-500ms performance contract, then clean up the code quality debt that leaks diagnostic output and breaks the test suite.

## Phases

- [x] **Phase 1: Critical Bug Fixes** - Restore comments sync, unblock stuck SyncEngine operations, wire notification deep-linking, and remove the hardcoded nil from Analytics Dashboard (completed 2026-03-06)
- [x] **Phase 2: Security Hardening** - Proxy Cerebras through a server-side Edge Function and migrate auth token storage to iOS Keychain (completed 2026-03-06)
- [x] **Phase 3: Performance** - Enforce sub-500ms cold start, eliminate duplicate carousel work, add concurrent SQLite reads, and audit cache-first screen loads (completed 2026-04-22)
- [ ] **Phase 4: Code Quality** - Replace all 212 raw print() calls with Logger and fix the broken MultiDeviceSyncTests

## Phase Details

### Phase 1: Critical Bug Fixes
**Goal**: User-visible data failures are eliminated — comments persist, sync recovers without wiping app data, notification taps navigate to content, and the Analytics Dashboard shows real data
**Depends on**: Nothing (first phase)
**Requirements**: BUG-01, BUG-02, BUG-03, BUG-04
**Success Criteria** (what must be TRUE):
  1. A user can add a comment to a clip and it appears on another device after sync (commentRPCDisabled flag is never set)
  2. If a SyncEngine operation was blocked by a PGRST205 error and the backend schema is later corrected, the operation retries and succeeds without clearing app data
  3. Tapping a push notification opens the app and navigates directly to the relevant movie or TV show
  4. The Analytics Dashboard mood analysis section displays data instead of an empty/nil state
**Plans**: 5 plans

Plans:
- [ ] 01-01-PLAN.md — Wave 0 test stubs for all four bugs (RED baseline for TDD)
- [ ] 01-02-PLAN.md — BUG-01: Supabase migration + SQLite migration 3 + remove commentRPCDisabled flag
- [ ] 01-03-PLAN.md — BUG-02: Expose SyncEngine.unblockAndRetryBlockedOperations() and wire into performFullSyncOnLaunch
- [ ] 01-04-PLAN.md — BUG-03: Implement handleNotificationTap and add deepLinkTarget observer to MainTabView
- [ ] 01-05-PLAN.md — BUG-04: Implement calculateMoodAnalysis() in AnalyticsInsightsService and add dashboard placeholder

### Phase 2: Security Hardening
**Goal**: The Cerebras API key is never bundled in the app binary, and auth session tokens are encrypted at rest on device
**Depends on**: Phase 1
**Requirements**: SEC-01, SEC-02
**Success Criteria** (what must be TRUE):
  1. The Cerebras API key does not appear in the compiled .ipa or in the app bundle's Info.plist/xcconfig; all AI requests route through a Supabase Edge Function
  2. Auth session tokens survive an app restart and are stored in iOS Keychain, not in a plain UserDefaults .plist file
  3. Existing logged-in users are silently migrated to Keychain storage on first launch after the update (no forced re-login)
**Plans**: 3 plans

Plans:
- [ ] 02-00-PLAN.md — Wave 0 RED test stubs for KeychainStorage and AuthService migration (TDD baseline for SEC-02)
- [ ] 02-01-PLAN.md — SEC-01: Create cerebras-proxy Edge Function; update CerebrasService to call it; remove key from Config/xcconfig
- [ ] 02-02-PLAN.md — SEC-02: Implement KeychainStorage adapter and update AuthService with Keychain wiring and migration

### Phase 3: Performance
**Goal**: The app reaches a usable Discovery screen in under 500ms from cache on every cold start, with no duplicate work and no UI-blocking SQLite reads
**Depends on**: Phase 1
**Requirements**: PERF-01, PERF-02, PERF-03, PERF-04
**Success Criteria** (what must be TRUE):
  1. A cold launch with a warm cache (subsequent launch) shows the Discovery screen with content in under 500ms — no spinner, no blank state
  2. Personalization carousels are generated exactly once per cold start (single call site, no duplicate computation)
  3. SQLite read operations for Discovery, Movie/TV detail, and Clips screens do not block on concurrent writes — cached content appears instantly
  4. Discovery, Movie/TV detail, and Clips screens each load cached content before initiating any network refresh
**Plans**: 4 plans

Plans:
- [ ] 03-00-PLAN.md — Wave 0 RED test stubs for all four performance requirements (TDD baseline)
- [ ] 03-01-PLAN.md — PERF-01 + PERF-02: Fix loadCachedContentSync() via hasPersonalizedDiscoveryCache; guard generatePersonalizedCarousels with carouselsGeneratedThisLaunch Bool
- [ ] 03-02-PLAN.md — PERF-03: Split SQLiteService into writer + concurrent reader queue; open read-only SQLite connection for WAL concurrent reads
- [ ] 03-03-PLAN.md — PERF-04: Remove PRO gate from Movie/TV detail cache reads; verify Discovery and Clips cache-first paths

### Phase 4: Code Quality
**Goal**: No raw print() statements exist in production code paths, and the only non-trivial test in the project compiles and passes
**Depends on**: Phase 1
**Requirements**: QUAL-01, QUAL-02
**Success Criteria** (what must be TRUE):
  1. A release build produces zero print() output — all 212 raw print() calls are replaced with Logger.info/debug/warning/error equivalents
  2. MultiDeviceSyncTests.swift compiles without errors and all test cases pass, covering SyncEngine and ConflictResolver conflict resolution paths
**Plans**: 2 plans

Plans:
- [ ] 04-01-PLAN.md — QUAL-01: Replace all 186 raw print() calls with Logger across 28 production files
- [ ] 04-02-PLAN.md — QUAL-02: Rewrite MultiDeviceSyncTests.swift using ConflictResolver and SyncEngine APIs

## Progress

**Execution Order:**
Phases execute in order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Critical Bug Fixes | 5/5 | Complete   | 2026-03-06 |
| 2. Security Hardening | 3/3 | Complete   | 2026-03-06 |
| 3. Performance | 4/4 | Complete   | 2026-04-22 |
| 4. Code Quality | 1/2 | In Progress|  |
