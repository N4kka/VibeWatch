# VibeWatch

## What This Is

VibeWatch is an iOS app (SwiftUI, iOS 16+) that lets users discover, track, and watch movies and TV shows. It combines a personalized Discovery feed, a TikTok-style Clips feed for trailers, AI-powered recommendations via Cerebras, watchlists with offline-first SQLite sync to Supabase, and gamification. It targets film enthusiasts who want one place to manage what they watch and get fast, personalized suggestions.

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

### Active

- [ ] Comments sync to Supabase (currently silently fail due to missing `updated_at` column in backend schema)
- [ ] SyncEngine recovers from permanently stuck operations (PGRST205 blocking with no recovery path)
- [ ] Push notification taps navigate to relevant content (current handler is a no-op stub)
- [ ] Analytics Dashboard shows mood analysis (currently hardcoded nil)
- [ ] Cerebras API key never leaves the server (currently bundled in app — move to Supabase Edge Function proxy)
- [ ] Auth session tokens stored in Keychain (currently in unencrypted UserDefaults)
- [ ] App launch and all main screens load in under 500ms from cache
- [ ] Personalization carousels generated once per cold start (currently called twice)
- [ ] SQLite supports concurrent reads (currently single queue blocks reads during writes)
- [ ] All 212 print() calls replaced with Logger (currently leak diagnostic output in release builds)
- [ ] MultiDeviceSyncTests updated to use SyncEngine (currently broken — references deleted SyncManager)

### Out of Scope

- New features — this milestone is strictly stabilization and performance
- UI file refactors (ClipsView 1764 lines, ListsView 1602 lines) — not user-visible
- YouTube ToS risk — app uses the official IFrame Player API, not a violation

## Context

The codebase is brownfield with a solid architecture: MVVM, protocol-backed services, DependencyContainer, structured concurrency throughout. The main gaps before production are: a Supabase schema mismatch breaking comments sync, an unrecoverable SyncEngine blocked state, a notification tap stub, a security risk from the Cerebras key being bundled, auth tokens in UserDefaults instead of Keychain, and cold-start performance issues from duplicate work and a single SQLite queue.

The codebase map is in `.planning/codebase/`.

## Constraints

- **Platform**: iOS 16.0+ — no API below iOS 16
- **Architecture**: Must not add new third-party dependencies — fix with existing stack
- **Scope**: No new user-visible features — fixes and performance only
- **Backend**: Supabase (PostgreSQL + Edge Functions) — schema changes require SQL migrations

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Proxy Cerebras via Supabase Edge Function | API key must not be extractable from IPA | — Pending |
| Keychain for auth tokens | UserDefaults is unencrypted — session tokens need encryption at rest | — Pending |
| Single SQLite writer + concurrent readers | WAL mode already enabled — add reader queue for parallel reads without writer contention | — Pending |

---
*Last updated: 2026-03-05 after initialization*
