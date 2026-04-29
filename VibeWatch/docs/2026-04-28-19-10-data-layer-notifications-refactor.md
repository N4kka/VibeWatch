# Data Layer And Notifications Refactor

## Overview

Refactor VibeWatch's data access and notification architecture so Lists, Detail, and Discovery render from SQLite immediately, then refresh in the background. The target architecture introduces repository protocols and live implementations, injects repositories through SwiftUI environment values, migrates priority view models to `@Observable`, and separates notifications into explicit local reminders, background local digest, and APNs server-driven push.

Source plan: `/Users/nicola/.claude/plans/refactoring_plan.md`.

Current status before implementation:
- `git status --short` shows existing uncommitted edits in `.planning/config.json`, `VibeWatchApp/Core/Services/ListManager.swift`, `VibeWatchApp/Core/Supabase/SupabaseClient.swift`, and `VibeWatchApp/Tests/MultiDeviceSyncTests.swift`.
- There are also untracked planning files under `.planning/` and sibling directories outside this repo (`../Sleepy/`, `../VibeWatchWeb/`).
- `project.pbxproj` currently has `SWIFT_VERSION = 5.0` for app and test targets.
- `VibeWatchApp/VibeWatchAppRelease.entitlements` currently has `aps-environment` set to `development`, not `production`.
- `SQLiteService` already has the `SQLiteTable` whitelist and existing cache tables such as `media_details_cache`, `detail_cache`, `discovery_cache`, and `trailers_cache`.
- `SQLiteMigrations.runPersonalizationMigrations()` currently targets `latestVersion = 6`.
- `DependencyContainer` already exists and is the right place to add repository factories.
- `ClipsRepository` exists as a minimal repository pattern, but the new repositories should use explicit constructor injection and avoid reading `.shared` internally.

## Technical Approach

Execution will be phased. Each phase should leave the app buildable and should be verified before moving on. Because the working tree is already dirty, Fase 0 starts with a user decision: preserve current edits by committing them or stashing them before tagging `pre-refactor`.

### Phase 0: Preparation

Files:
- Modify `VibeWatchApp.xcodeproj/project.pbxproj`
- Modify `VibeWatchApp/VibeWatchAppRelease.entitlements`

Steps:
1. Choose how to preserve current uncommitted changes: commit or stash.
2. Create `pre-refactor` tag on a clean HEAD.
3. Raise app and test targets to Swift 6.0 and set strict concurrency to complete.
4. Set release entitlements to production APNs.
5. Build the app and resolve compiler errors caused by Swift 6 settings.

Verification:
- `git tag --list pre-refactor`
- `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Phase 1: SQLite Schema And Repository Protocols

Files:
- Create `VibeWatchApp/Core/Database/Migrations/Migration7_RepositoryLayerCache.swift`
- Modify `VibeWatchApp/Core/Database/SQLiteMigrations.swift`
- Modify `VibeWatchApp/Core/Database/SQLiteService.swift`
- Create `VibeWatchApp/Core/Repositories/ListRepository.swift`
- Create `VibeWatchApp/Core/Repositories/MediaRepository.swift`
- Create `VibeWatchApp/Core/Repositories/DiscoveryRepository.swift`
- Create `VibeWatchApp/Core/Repositories/NotificationRepository.swift`

Steps:
1. Add migration 7 to create `media_availability`, `discovery_carousels`, `discovery_carousel_items`, and local `notification_events`.
2. Add idempotent TTL columns to `media_details_cache`.
3. Add new tables to `SQLiteTable`.
4. Add repository protocols using `AsyncStream` for reads and `async throws` for writes.

Verification:
- Migration compiles and is idempotent.
- New protocols compile with no live implementation wired into views yet.
- `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Phase 2: Live Repository Implementations And Tests

Files:
- Create `VibeWatchApp/Core/Repositories/Live/LiveListRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Live/LiveMediaRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Live/LiveDiscoveryRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Live/LiveNotificationRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Mock/MockListRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Mock/MockMediaRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Mock/MockDiscoveryRepository.swift`
- Create `VibeWatchApp/Core/Repositories/Mock/MockNotificationRepository.swift`
- Modify `VibeWatchApp/Core/Supabase/SupabaseClient.swift`
- Possibly modify `VibeWatchApp/Core/Services/ListManager.swift`
- Create repository tests under `VibeWatchAppTests/Repositories/`

Steps:
1. Implement SWR repositories: yield SQLite snapshot first, refresh remotely in the background, upsert local SQLite, then yield fresh data.
2. Route writes through optimistic local updates plus `SyncEngine` outbox.
3. Reuse existing `ListManager` mark-as-seen behavior instead of duplicating it.
4. Split media TTLs: metadata 7 days, availability 12 hours.
5. Ensure Discovery cache is per user and `chooseForYou` is always position 0.
6. Replace raw Supabase RPC URLSession calls for `apply_mutations` and `merge_user_preferences` with SDK RPC calls using `Encodable` request structs.
7. Add minimum repository tests for SWR, TTL behavior, and Discovery ordering.

Verification:
- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'`

### Phase 3: Dependency Injection Wiring

Files:
- Modify `VibeWatchApp/App/DI/DependencyContainer.swift`
- Create `VibeWatchApp/App/DI/RepositoryEnvironment.swift`
- Modify `VibeWatchApp/App/VibeWatchApp.swift`

Steps:
1. Add lazy repository factories to `DependencyContainer`.
2. Add SwiftUI environment entries for the four repositories.
3. Inject live repositories at the app root.
4. Keep existing view model behavior unchanged until Phase 4.

Verification:
- App builds and launches with behavior unchanged.

### Phase 4: Priority ViewModel Migration To `@Observable`

Files:
- Modify `VibeWatchApp/Features/Lists/ViewModels/ListsViewModel.swift`
- Modify `VibeWatchApp/Features/Discovery/ViewModels/MovieDetailViewModel.swift`
- Modify `VibeWatchApp/Features/Discovery/ViewModels/TVShowDetailViewModel.swift`
- Modify `VibeWatchApp/Features/Discovery/ViewModels/DiscoveryViewModel.swift`
- Modify corresponding views in `Features/Lists/Views/` and `Features/Discovery/Views/`
- Add or update tests for the migrated view models.

Steps:
1. Migrate `ListsViewModel` first as the reference implementation.
2. Inject repositories via initializers; views read repositories from `@Environment`.
3. Use `@State` for `@Observable` view models in views.
4. Move the Detail "Seen" action onto `ListRepository.markAsSeen`.
5. Remove direct `.shared` access from the migrated view models.

Verification:
- Snapshot-style tests for `ListsViewModel`, `MovieDetailViewModel`, and `DiscoveryViewModel` with mocks.
- Manual smoke test: second launch in airplane mode renders Lists, Detail, and Discovery from SQLite.

### Phase 5: Discovery Cache Cleanup

Files:
- Modify `VibeWatchApp/Core/Repositories/Live/LiveDiscoveryRepository.swift`
- Modify `VibeWatchApp/Core/Services/DiscoveryPersonalizationService.swift`

Steps:
1. Keep DiscoveryPersonalizationService as a data fetcher.
2. Move caching and TTL ownership to the repository.
3. Enforce `chooseForYou` as first carousel for every user.

Verification:
- "Choose for You" remains first.
- Network refresh occurs only when cache is stale.

### Phase 6: Local User-Initiated Notifications

Files:
- Modify `VibeWatchApp/Core/Services/SmartNotificationService.swift`
- Modify `VibeWatchApp/Core/Repositories/Live/LiveNotificationRepository.swift`

Steps:
1. Remove all 5-second `UNTimeIntervalNotificationTrigger` scheduling.
2. Remove notification scheduling from view `onAppear` paths.
3. Keep only explicit user reminders, scheduled with `UNCalendarNotificationTrigger`.

Verification:
- `rg "UNTimeIntervalNotificationTrigger" VibeWatchApp` returns no production usages.
- No random local notification fires while app is open.

### Phase 7: Local Background Digest Notifications

Files:
- Modify `VibeWatchApp/Core/Services/NotificationBackgroundTask.swift` or create `LocalDigestBackgroundTask.swift`

Steps:
1. Use existing `com.vibewatch.smart-notifications` BGTask identifier.
2. Schedule `BGAppRefreshTaskRequest` roughly every 6 hours.
3. Query SQLite for local notification candidates.
4. Deduplicate through `LiveNotificationRepository.wasAlreadySent`.
5. Use calendar triggers, not time interval triggers.

Verification:
- Device-only smoke test with Console.app filter on `com.vibewatch.smart-notifications`.

### Phase 8: APNs Server-Driven Notifications

Files:
- Modify `VibeWatchApp/App/AppDelegate.swift`
- Modify `VibeWatchApp/App/VibeWatchApp.swift` or navigation handling as needed.
- Modify `supabase/functions/process-notifications/index.ts`
- Add Supabase migrations for `device_tokens` and `notification_events_remote`.

Steps:
1. Add device token registration and upsert through `NotificationRepository`.
2. Add notification response deep-link handling.
3. Add additive Supabase tables only.
4. Update edge function to send APNs payloads and record remote notification events.
5. Keep the confirmed daily morning notification window.

Verification:
- Real device login inserts token.
- Manual edge function trigger sends push.
- Tapping push navigates to the correct media detail.

### Phase 9: Cleanup

Files:
- Migrated view models and views.
- `DependencyContainer`.
- Legacy Discovery caching paths.
- `AGENTS.md` only if repo conventions actually change.

Steps:
1. Remove `Combine` imports from migrated view models when no longer needed.
2. Audit `.shared` usage in migrated feature view models.
3. Remove obsolete Discovery cache code.
4. Document any remaining non-migrated view models.

Verification:
- `rg "\\.shared" VibeWatchApp/Features`
- `rg "ObservableObject" VibeWatchApp/Features`
- `rg "UNTimeIntervalNotificationTrigger" VibeWatchApp`
- Full build and test suite.

## Status

In progress.

Pre-implementation decisions:
- Existing local edits were preserved with commit `ebf4bbd` (`chore: preserve pre-refactor workspace state`).
- Tag `pre-refactor` was created on that preserved HEAD.
- Refactor implementation is happening in worktree `.worktrees/data-layer-notifications-refactor` on branch `refactor/data-layer-notifications`.

Completed:
- Phase 0 build settings updated to Swift 6.0 with `SWIFT_STRICT_CONCURRENCY = complete` for app and test targets.
- Release APNs entitlement changed from `development` to `production`.
- Ignored local `Secrets.xcconfig` and `Config.swift` were copied into the worktree for build verification only; they are not tracked.
- Swift 6 concurrency build blockers discovered by Fase 0 were fixed with minimal compatibility changes.
- Verification: `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build` succeeded.
- Sync/conflict test regressions exposed by the Swift 6 baseline were fixed before starting Phase 1:
  - `ConflictResolver` now preserves `.union` strategy metadata when union resolution falls back to last-write-wins.
  - XP level thresholds now match the documented level starts.
  - `SyncStateMachine` treats same-state transitions as no-op successes before validity checks.
  - `SyncEngineTests` can disable immediate outbox pushes to keep queue-count assertions deterministic.
- Phase 1 repository-layer schema and protocols were added:
  - Migration 7 creates `media_availability`, `discovery_carousels`, `discovery_carousel_items`, and `notification_events`.
  - Migration 7 adds idempotent `metadata_expires_at` and `availability_expires_at` TTL columns to `media_details_cache`.
  - New repository protocols define AsyncStream read surfaces and async throwing write/refresh methods for Lists, Media, Discovery, and Notifications.
  - SQLite table whitelist now includes the new repository cache tables.
  - `DatabaseMigrationTests.testPersonalizationMigration7AddsRepositoryLayerCacheSchema` covers schema creation and migration idempotency.
- Phase 2 live/mock repository implementations were added:
  - `LiveMediaRepository` yields SQLite snapshots first, refreshes stale metadata/availability via injected remote loaders, and stores availability with a 12-hour TTL.
  - `LiveDiscoveryRepository` persists carousels/items to SQLite, refreshes via an injected carousel provider, records interactions, and normalizes `choose_for_you` to position 0.
  - `LiveListRepository` performs optimistic SQLite list/list-item writes and queues sync operations.
  - `LiveNotificationRepository` records local notification events and deduplicates sent events.
  - Mock repositories were added for Lists, Media, Discovery, and Notifications.
  - Supabase `apply_mutations` and `merge_user_preferences` now use SDK RPC calls with Encodable payloads instead of manual RPC URLSession requests.
  - `SQLiteService.upsert`, `update`, and `delete` now write through the writer connection instead of routing write SQL through the read-only query path.
  - Repository tests cover SWR details, availability TTL, and Discovery ordering.
- Phase 3 dependency injection wiring was added:
  - `DependencyContainer` now owns lazy live repository factories for Lists, Media, Discovery, and Notifications.
  - `RepositoryEnvironment` adds SwiftUI environment values for the four repository protocols.
  - The app root injects the live repositories alongside the existing `DependencyContainer`.
  - Repository protocols now conform to `Sendable` so they can be stored safely in SwiftUI environment values under Swift 6.
  - `RepositoryEnvironmentTests` covers container factories and environment override behavior with mocks.
- Phase 4a Lists migration was added:
  - `ListsViewModel` is now an `@Observable` model driven by injected `ListRepository` and `userId`.
  - The primary `ListsView` reads `ListRepository` from SwiftUI environment and stores the model with `@State`.
  - List creation, deletion, item removal, watchlist add, and mark-as-seen operations in the primary Lists screen route through `ListRepository`.
  - `CreateListView` now receives a repository-backed model and an explicit Pro-state value instead of requiring a new runtime environment object.
  - `ListsViewModelTests` covers loading repository snapshots and creating custom lists through the injected repository.
  - Post-test bugfix: `LiveListRepository` now hydrates authenticated lists from Supabase into SQLite after the initial local snapshot, and `ListsViewModel` consumes the final repository snapshot instead of stopping at the first empty local snapshot. This fixes fresh-device authenticated list views showing empty while new local writes appeared immediately.
  - Post-production-data cleanup: duplicate default lists are normalized app-side and a Supabase SQL runbook was added to merge existing duplicate `watchlist`, `seen`, `liked`, and `disliked` rows into the list with the most items.
- Phase 4b Detail view model migration was added:
  - `MovieDetailViewModel` and `TVShowDetailViewModel` are now `@Observable` models.
  - Both detail view models load their first detail snapshot from injected `MediaRepository`, allowing cached repository data to render before supplemental refresh work completes.
  - `MovieDetailView` and `TVShowDetailView` read `mediaRepository` from SwiftUI environment and store repository-backed view models with `@State`.
  - `DependencyContainer` detail factories now pass the live `mediaRepository`.
  - `DetailViewModelRepositoryTests` covers movie and TV detail snapshots with `MockMediaRepository`.
  - Verification: full `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'` passed with 125 tests.
  - Remaining Phase 4 work: migrate `DiscoveryViewModel` and secondary list surfaces such as custom list detail/edit paths away from direct `ListManager` usage.
- Phase 4c Discovery view model migration was added:
  - `DiscoveryViewModel` is now an `@Observable` model driven by injected `DiscoveryRepository` and explicit `userId`.
  - The primary Discovery read path consumes `DiscoveryCarouselSnapshot` streams and maps them into the existing `PersonalizedCarousel` UI model.
  - `DiscoveryView` reads `discoveryRepository` from SwiftUI environment and recreates its content view when the authenticated user changes.
  - `DependencyContainer.makeDiscoveryViewModel()` now injects the live `DiscoveryRepository`.
  - Existing global filters, local filter persistence, pro-only hide watched/disliked behavior, analytics, gamification, and interaction logging remain scoped as-is for this batch.
  - `DiscoveryViewModelRepositoryTests` covers repository snapshot loading with `MockDiscoveryRepository`.
  - Verification: full `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'` passed with 126 tests.
  - Remaining Phase 4 work: migrate secondary list surfaces such as custom list detail/edit paths away from direct `ListManager` usage.

Verification notes:
- Build succeeded with `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build`.
- Targeted sync/conflict suite succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/ConflictResolverTests -only-testing:VibeWatchAppTests/SyncStateMachineTests -only-testing:VibeWatchAppTests/SyncEngineTests`.
- Phase 1 migration test succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/DatabaseMigrationTests/testPersonalizationMigration7AddsRepositoryLayerCacheSchema`.
- Phase 2 repository tests succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/LiveMediaRepositoryTests -only-testing:VibeWatchAppTests/LiveDiscoveryRepositoryTests`.
- Phase 4a Lists targeted tests succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/AppNavigationManagerTests -only-testing:VibeWatchAppTests/ListsViewModelTests`.
- Phase 4a list hydration regression tests first failed as expected on the missing repository remote loader, then succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/LiveListRepositoryTests -only-testing:VibeWatchAppTests/ListsViewModelTests`
  Result: 4 tests, 0 failures.
- Phase 4c Discovery view model targeted test succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/DiscoveryViewModelRepositoryTests`
  Result: 1 test, 0 failures.
- Full test suite succeeded after Phase 4c with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`
  Result: 126 tests, 0 failures.
- Full test suite succeeded after Phase 4a with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`
  Result: 119 tests, 0 failures.
- Full test suite succeeded after the list hydration regression fix with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`
  Result: 121 tests, 0 failures.
- Standalone build succeeded after Phase 4a with:
  `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build`.
- Phase 3 repository environment test succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/RepositoryEnvironmentTests`.
- Full test suite succeeded with:
  `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`.
- Fresh app build succeeded with:
  `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build`.
- Build still emits existing warnings unrelated to the current checkpoint; they are intentionally left for later cleanup.

## Pros & Cons

Pros:
- Offline-first rendering improves Lists, Detail, and Discovery perceived performance.
- Repositories create a clear boundary between SwiftUI view models, SQLite, Supabase, TMDB, StreamingAvailabilityService, and SyncEngine.
- SWR keeps reads fast while preserving fresh remote data.
- Notification channels become explicit and auditable, removing random in-app local notifications.
- Additive SQLite and Supabase migrations reduce production data risk.

Cons:
- Swift 6 strict concurrency may expose a large number of existing actor/sendability issues before feature work can proceed.
- The repository layer touches shared services and high-traffic views, so the blast radius is significant.
- APNs work needs manual Apple Developer and Supabase secret setup outside Codex.
- BGTask behavior cannot be fully validated in simulator.
- The dirty starting tree must be preserved carefully before tagging and refactoring.
