# VibeWatch

## What This Is

VibeWatch is a production iOS app (SwiftUI, iOS 16+) that lets users discover, track, and watch movies and TV shows. It combines a personalized Discovery feed, a TikTok-style Clips feed for trailers, AI-powered recommendations via Cerebras (server-proxied), watchlists with offline-first SQLite sync to Supabase, and gamification. Auth tokens are encrypted at rest via iOS Keychain. It targets film enthusiasts who want one place to manage what they watch and get fast, personalized suggestions.

## Core Value

Content and user data load under 500ms — the app feels instant from first tap, never shows a spinner for cached data, and never silently loses user data.

## Requirements

### Validated

- ✓ MVVM architecture with SwiftUI — existing
- ✓ Offline-first SQLite with Supabase sync via SyncEngine outbox — existing
- ✓ Discovery feed with personalized carousels (TMDB + DiscoveryPersonalizationService) — existing
- ✓ Clips feed with YouTube IFrame Player — existing
- ✓ AI chat/recommendations via Cerebras — existing
- ✓ Lists (watchlist, custom lists) with CRUD and cloud sync — existing
- ✓ Gamification (badges, streaks) — existing
- ✓ RevenueCat Pro subscription + paywall — existing
- ✓ AdMob ads for free users — existing
- ✓ Push notifications via FCM — existing
- ✓ 20-language localization — existing
- ✓ Onboarding + auth (Supabase email/OAuth) — existing
- ✓ Comments sync to Supabase — v1.0 (schema migration + commentRPCDisabled removed)
- ✓ SyncEngine PGRST205 recovery — v1.0 (unblockAndRetryBlockedOperations wired at launch)
- ✓ Push notification deep-link navigation — v1.0 (SmartNotificationService + MainTabView observer)
- ✓ Analytics Dashboard mood analysis — v1.0 (calculateMoodAnalysis implemented)
- ✓ Cerebras API key server-side only — v1.0 (Edge Function proxy with JWT auth)
- ✓ Auth session tokens in Keychain — v1.0 (KeychainStorage with silent UserDefaults migration)
- ✓ App launch <500ms from cache — v1.0 (SQLite cache-first + concurrent reader queue)
- ✓ Personalization carousels generated once per cold start — v1.0 (carouselsGeneratedThisLaunch guard)
- ✓ SQLite concurrent reads — v1.0 (WAL + dedicated readerQueue + FULLMUTEX read-only connection)
- ✓ Logger replaces all print() calls — v1.0 (186 calls across 28 files replaced)
- ✓ MultiDeviceSyncTests compiles and passes — v1.0 (rewritten with real SyncEngine/ConflictResolver APIs)

### Active

- [ ] ClipsView.swift (1764 lines) refactored into focused subviews
- [ ] ListsView.swift (1602 lines) refactored into focused subviews
- [ ] DependencyContainer fully decouples services from .shared singletons
- [ ] ConflictResolverTests pre-existing failures fixed (testFullConflictResolutionFlow, testLevelCalculation)

### Out of Scope

- YouTube ToS risk — app uses the official IFrame Player API, not a violation

## Context

v1.0 shipped 2026-05-07. All production blocking issues resolved. The codebase is now stable: data integrity intact, auth secure, cold-start instant from cache, no diagnostic output in release builds. Architecture remains MVVM with protocol-backed services. Remaining debt: large view files (ClipsView 1764 LOC, ListsView 1602 LOC) and some pre-existing test failures in ConflictResolverTests.

Codebase: ~55,600 Swift LOC. Tech stack: SwiftUI, SQLite (custom WAL), Supabase (PostgreSQL + Edge Functions), RevenueCat, AdMob, FCM.

The codebase map is in `.planning/codebase/`.

## Constraints

- **Platform**: iOS 16.0+ — no API below iOS 16
- **Architecture**: Must not add new third-party dependencies — fix with existing stack
- **Backend**: Supabase (PostgreSQL + Edge Functions) — schema changes require SQL migrations

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Proxy Cerebras via Supabase Edge Function | API key must not be extractable from IPA | ✓ Deployed — `cerebras-proxy` with JWT auth and token usage logging |
| Keychain for auth tokens | UserDefaults is unencrypted — session tokens need encryption at rest | ✓ KeychainStorage with kSecAttrAccessibleAfterFirstUnlock; silent migration |
| Single SQLite writer + concurrent readers | WAL mode already enabled — add reader queue for parallel reads | ✓ writerQueue (serial) + readerQueue (concurrent) + FULLMUTEX read-only connection |
| commentRPCDisabled removed by deletion | Schema fix makes client-side disable unnecessary — simpler than flag management | ✓ Flag fully deleted; RPC called unconditionally |
| carouselsGeneratedThisLaunch on AppState | Resets on AppState re-creation in tests; correct scope for per-launch dedup | ✓ Both call sites guarded; single generation per cold start |
| SQLITE_OPEN_FULLMUTEX for readerDb | NOMUTEX caused illegal multi-threaded access crash on concurrent queue | ✓ Stable; concurrent reads work correctly |
| waitForDiscoveryContentReady SQLite early exit | ContentCacheManager poll was defeating Phase 3 instant-launch fix | ✓ Splash exits immediately on warm SQLite cache |

---
*Last updated: 2026-05-07 after v1.0 milestone*
