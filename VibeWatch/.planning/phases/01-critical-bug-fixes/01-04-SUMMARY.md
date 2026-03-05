---
phase: 01-critical-bug-fixes
plan: "04"
subsystem: notifications
tags: [push-notifications, deep-link, navigation, swiftui, appnavigationmanager]

# Dependency graph
requires:
  - phase: 01-critical-bug-fixes/01-01
    provides: AppNavigationManager.swift with handle(userInfo:) and clearDeepLinkTarget() already implemented

provides:
  - SmartNotificationService.handleNotificationTap full implementation calling AppNavigationManager.shared on MainActor
  - MainTabView deepLinkTarget observer routing notification taps to MovieDetailView or TVShowDetailView
  - Cold-launch navigation support via .onAppear check on deepLinkTarget
  - Discovery tab fallback when notification payload has no valid media_id/media_type
  - Equatable conformance on DeepLinkTarget (comparing by mediaId + mediaType)

affects: [notification-tap-testing, deep-link-routing]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Notification tap -> AppNavigationManager.shared.handle(userInfo:) on MainActor -> @Published deepLinkTarget -> .onChange in MainTabView -> detail view push"
    - "Movie placeholder pattern: construct minimal Movie(id:...) to trigger existing navigationDestination(item:) without introducing new navigation mechanism"

key-files:
  created: []
  modified:
    - VibeWatchApp/Core/Services/SmartNotificationService.swift
    - VibeWatchApp/App/MainTabView.swift
    - VibeWatchApp/Core/Utilities/AppNavigationManager.swift

key-decisions:
  - "Add Equatable to DeepLinkTarget comparing by mediaId+mediaType (not UUID id) so .onChange(of:) compiles — UUID serves only Identifiable, content identity is media id+type"
  - "Use minimal Movie placeholder to trigger existing navigationDestination(item: $selectedMovie) — avoids introducing a second navigation mechanism and stays consistent with existing pattern"
  - "Call clearDeepLinkTarget() inside handleDeepLinkTarget() after navigation state is set, not inside handleNotificationTap — view owns lifecycle of deepLinkTarget consumption"

patterns-established:
  - "Deep link chain: SmartNotificationService -> AppNavigationManager.shared -> MainTabView .onChange -> detail view"

requirements-completed: [BUG-03]

# Metrics
duration: 40min
completed: 2026-03-05
---

# Phase 1 Plan 04: Fix BUG-03 Notification Tap Navigation Summary

**Push notification taps now route to MovieDetailView or TVShowDetailView via SmartNotificationService calling AppNavigationManager on MainActor, with MainTabView .onChange observer and cold-launch .onAppear fallback**

## Performance

- **Duration:** 40 min
- **Started:** 2026-03-05T16:52:44Z
- **Completed:** 2026-03-05T17:32:24Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Replaced empty `handleNotificationTap` stub with full AppNavigationManager call path, Discovery fallback, and early-return logging
- Added `deepLinkTarget` observer to MainTabView that switches to Discovery tab and pushes MovieDetailView or TVShowDetailView using the existing `navigationDestination(item: $selectedMovie)` pattern
- Cold-launch case handled via `.onAppear` checking deepLinkTarget before any `onChange` fires
- AppNavigationManagerTests GREEN, full build succeeds

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement SmartNotificationService.handleNotificationTap** - `7f5a70f` (feat)
2. **Task 2: Add deepLinkTarget observer to MainTabView** - `a908bfd` (feat)

## Files Created/Modified
- `VibeWatchApp/Core/Services/SmartNotificationService.swift` - handleNotificationTap now calls AppNavigationManager.shared.handle(userInfo:) on MainActor with Discovery fallback
- `VibeWatchApp/App/MainTabView.swift` - Added @ObservedObject navigationManager, .onChange(of: deepLinkTarget), .onAppear cold-launch handler, handleDeepLinkTarget() helper
- `VibeWatchApp/Core/Utilities/AppNavigationManager.swift` - Added Equatable conformance to DeepLinkTarget (required by .onChange)

## Decisions Made
- **Equatable on DeepLinkTarget:** `.onChange(of:)` in SwiftUI requires the observed value to be `Equatable`. Added custom `==` comparing `mediaId` and `mediaType`, not the `UUID id` field (which is for `Identifiable` only). Two targets with the same content are equal for change detection purposes.
- **Movie placeholder pattern:** The existing `navigationDestination(item: $selectedMovie)` pattern needs a `Movie` object but detail views only use `movie.id`. Rather than introducing a new `navigationDestination` for deep links, a minimal `Movie` placeholder is constructed with only `id` set, keeping navigation consistent with existing code.
- **clearDeepLinkTarget() placement:** Called inside `handleDeepLinkTarget()` after setting `selectedMovie`, not inside `handleNotificationTap` (as documented in RESEARCH.md pitfall). The view is responsible for consuming the deep link target.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added Equatable conformance to DeepLinkTarget**
- **Found during:** Task 2 (adding .onChange observer to MainTabView)
- **Issue:** `DeepLinkTarget` did not conform to `Equatable`, causing compiler error "referencing instance method 'onChange(of:initial:_:)' on 'Optional' requires that 'DeepLinkTarget' conform to 'Equatable'"
- **Fix:** Added `Equatable` with custom `==` operator comparing `mediaId` and `mediaType` (not UUID)
- **Files modified:** VibeWatchApp/Core/Utilities/AppNavigationManager.swift
- **Verification:** Build succeeded, AppNavigationManagerTests PASSED
- **Committed in:** a908bfd (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical conformance)
**Impact on plan:** Required for .onChange(of:) to compile. No scope creep.

## Issues Encountered
- After Task 1 build succeeded, clearing corrupted DerivedData/Build caused xcodebuild to re-resolve all SPM packages. Some binary XCFramework artifacts (Firebase, Google Ads) were missing from cache, and a git submodule clone (swift-protobuf -> protobuf) failed intermittently. Resolved by manually providing the protobuf submodule content and retrying the build until the Xcode build service stabilized.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- BUG-03 fixed: notification taps now navigate to correct detail views in both background and cold-launch scenarios
- Push notification routing is complete end-to-end
- Manual verification recommended: kill app, tap notification in Notification Center, verify correct detail view opens

---
*Phase: 01-critical-bug-fixes*
*Completed: 2026-03-05*
