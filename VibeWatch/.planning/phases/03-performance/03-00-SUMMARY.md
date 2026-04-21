---
phase: 03-performance
plan: "00"
subsystem: testing
tags: [xctest, tdd, sqlite, performance, red-baseline]

# Dependency graph
requires: []
provides:
  - "PerformanceTests.swift RED stubs for PERF-01 through PERF-04 (6 test methods, 4 MARK sections)"
  - "Compile-time proof that hasPersonalizedDiscoveryCache, readerQueue, carouselsGeneratedThisLaunch do not yet exist"
affects:
  - 03-01-PLAN
  - 03-02-PLAN
  - 03-03-PLAN

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TDD RED baseline: test file references nonexistent production members to enforce compile-error gate before implementation"

key-files:
  created:
    - VibeWatchAppTests/PerformanceTests.swift
  modified:
    - VibeWatchApp.xcodeproj/project.pbxproj

key-decisions:
  - "AppState.init(authService:) requires a parameter — testCarouselGeneratedOncePerLaunch uses it directly with @MainActor note; GREEN test will need @MainActor or async test context when plan 03-01 ships"
  - "PERF-04 stubs use XCTFail() as RED sentinel since memoryCache is private and ClipsRepository mock seam does not exist yet — accepted per plan spec"

patterns-established:
  - "RED baseline pattern: reference future stored properties by their target name/type so compile errors self-document exactly what production plans must add"

requirements-completed:
  - PERF-01
  - PERF-02
  - PERF-03
  - PERF-04

# Metrics
duration: 8min
completed: 2026-04-21
---

# Phase 3 Plan 00: Performance RED Baseline Summary

**XCTest RED baseline with 6 failing stubs covering PERF-01 to PERF-04 — compile errors on `hasPersonalizedDiscoveryCache`, `readerQueue`, and `carouselsGeneratedThisLaunch` confirm no production code exists yet**

## Performance

- **Duration:** 8 min
- **Started:** 2026-04-21T13:34:13Z
- **Completed:** 2026-04-21T13:42:00Z
- **Tasks:** 1
- **Files modified:** 2

## Accomplishments
- Created `VibeWatchAppTests/PerformanceTests.swift` with 6 test method stubs across 4 MARK sections (PERF-01, PERF-02, PERF-03, PERF-04)
- Registered `PerformanceTests.swift` in the `VibeWatchAppTests` Xcode target with correct PBXBuildFile, PBXFileReference, PBXGroup, and Sources build phase entries
- Verified RED state: `xcodebuild build-for-testing` produces 4 compile errors on the 3 required missing members (`hasPersonalizedDiscoveryCache` x2, `carouselsGeneratedThisLaunch`, `readerQueue`)
- No production source files modified

## Task Commits

Each task was committed atomically:

1. **Task 1: Write PerformanceTests RED stubs** - `a4fad0f` (test)

**Plan metadata:** (docs commit — see final_commit below)

## Files Created/Modified
- `VibeWatchAppTests/PerformanceTests.swift` — 6 RED test stubs in `final class PerformanceTests: XCTestCase` covering all 4 performance requirements
- `VibeWatchApp.xcodeproj/project.pbxproj` — Added C3D4E5F6A1B2C3D5 (PBXFileReference), C3D4E5F6A1B2C3D4 (PBXBuildFile), PBXGroup child, Sources build phase entry for PerformanceTests.swift

## Decisions Made
- `AppState.init(authService:)` takes a required parameter — the `testCarouselGeneratedOncePerLaunch` test references `AppState()` which will not compile for an additional `@MainActor` isolation reason alongside the missing property; this is acceptable at RED (two compile errors per the same test method is fine). The GREEN fix in plan 03-01 will need to consider the correct test initialisation pattern.
- PERF-04 stubs use `XCTFail("RED — ...")` as the RED sentinel because `memoryCache` is private on `DiscoveryPersonalizationService` and no mock `ClipsRepository` injection exists yet — per plan spec, this is the accepted fallback for inaccessible members.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered
- `xcodebuild -destination 'platform=iOS Simulator,name=iPhone 16'` failed (no exact match) — used simulator UUID `id=601C4430-6213-49E3-8A4D-3564B2B57E2A` instead. Future plans should use the UUID form or discover via `xcrun simctl list`.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- RED baseline established; plans 03-01, 03-02, and 03-03 can now implement the production members and drive this file to GREEN
- Plans should note: `AppState` init requires `authService:` parameter — tests using `AppState()` will need `@MainActor` context or a mock auth service injection

---
*Phase: 03-performance*
*Completed: 2026-04-21*
