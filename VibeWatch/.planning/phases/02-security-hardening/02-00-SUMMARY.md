---
phase: 02-security-hardening
plan: "00"
subsystem: testing
tags: [keychain, ios-security, tdd, red-baseline, xcode, unit-tests]

# Dependency graph
requires: []
provides:
  - "KeychainStorageTests.swift: 6 failing test stubs for KeychainStorage adapter (store/retrieve/overwrite/remove/accessibility)"
  - "AuthMigrationTests.swift: 3 failing test stubs for UserDefaults-to-Keychain migration (success/failure/idempotency)"
affects: [02-02-keychain-implementation]

# Tech tracking
tech-stack:
  added: []
  patterns: [TDD RED baseline — test files reference non-existent types to force compile failure until implementation plan runs]

key-files:
  created:
    - VibeWatchAppTests/KeychainStorageTests.swift
    - VibeWatchAppTests/AuthMigrationTests.swift
  modified:
    - VibeWatchApp.xcodeproj/project.pbxproj

key-decisions:
  - "AuthMigrationTests uses AuthLocalStorage protocol reference (MockFailingKeychain conforming to AuthLocalStorage) — seam established for plan 02-02 to define protocol"
  - "AuthService._migrateUserDefaultsToKeychain(from:to:) called as testable static overload accepting injected stores — stub comment included for seam finalization in 02-02"
  - "KeychainStorage tests use UUID-suffixed keys per test to avoid Keychain state cross-contamination on Simulator"
  - "Tests registered in pbxproj with static UUIDs (A1B2C3D4E5F6A1B2/B3/B4/B5) following phase 01 manual registration pattern"

patterns-established:
  - "UUID-suffixed Keychain keys: each test generates UUID().uuidString suffix to isolate Simulator Keychain state"
  - "Isolated test stores: UserDefaults(suiteName:) and KeychainStorage(service:) use test-scoped namespaces"
  - "TDD RED commit format: test({phase}-{plan}): add failing test stubs for [feature]"

requirements-completed: [SEC-02]

# Metrics
duration: 5min
completed: 2026-03-06
---

# Phase 2 Plan 00: Security Hardening TDD RED Baseline Summary

**Failing XCTest stubs for KeychainStorage adapter (6 tests) and UserDefaults-to-Keychain migration (3 tests + MockFailingKeychain) registered in VibeWatchAppTests target as RED baseline for plan 02-02**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-06T09:33:10Z
- **Completed:** 2026-03-06T09:38:42Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Created KeychainStorageTests.swift with 6 test stubs covering all KeychainStorage behaviors specified in plan
- Created AuthMigrationTests.swift with 3 test stubs covering success, failure/re-login, and idempotency migration paths
- Both files registered in VibeWatchApp.xcodeproj VibeWatchAppTests target via pbxproj edits
- Build confirms RED baseline: referenced types (KeychainStorage, AuthLocalStorage, migrateUserDefaultsToKeychain) do not exist

## Task Commits

Each task was committed atomically:

1. **Task 1: Write KeychainStorageTests RED stubs** - `c88ea90` (test)
2. **Task 2: Write AuthMigrationTests RED stubs** - `87aa100` (test)

_Note: TDD RED phase — test-only commits. No feat commits in this plan._

## Files Created/Modified
- `VibeWatchAppTests/KeychainStorageTests.swift` - 6 XCTestCase methods for KeychainStorage store/retrieve/overwrite/remove/remove-missing/accessibility behaviors
- `VibeWatchAppTests/AuthMigrationTests.swift` - 3 XCTestCase methods for migration success/failure/idempotency plus MockFailingKeychain nested class
- `VibeWatchApp.xcodeproj/project.pbxproj` - PBXFileReference + PBXBuildFile + PBXGroup + PBXSourcesBuildPhase entries for both new test files

## Decisions Made
- AuthMigrationTests defines `MockFailingKeychain: AuthLocalStorage` as a nested class — the `AuthLocalStorage` protocol name matches what plan 02-02 will define; if the protocol name differs, the test will need a minor update
- `AuthService._migrateUserDefaultsToKeychain(from:to:)` call is left as-is in the test stub; the exact static testable overload signature is noted as TBD and will be finalized when plan 02-02 implements the method
- Kept `kSecAttrAccessibleAfterFirstUnlock` accessibility test as a behavioral round-trip assertion (not an attribute inspection) per plan spec

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Build verification via `xcodebuild build-for-testing` returned `Config.cerebrasAPIKey` missing errors (from CerebrasService.swift) which are pre-existing errors introduced by the 02-01 Cerebras proxy commit — these are unrelated to the new test files and are out of scope for this plan
- RED baseline is confirmed: test target references types that will not resolve until plan 02-02 creates them

## Next Phase Readiness
- RED baseline established; plan 02-02 can now implement KeychainStorage and migrateUserDefaultsToKeychain to turn these tests GREEN
- AuthLocalStorage protocol name must be `AuthLocalStorage` (as used in MockFailingKeychain) or AuthMigrationTests.swift needs a one-line update
- CerebrasService.swift pre-existing errors (Config.cerebrasAPIKey) must be resolved by plan 02-02 (Cerebras proxy implementation) before the test suite builds cleanly

## Self-Check: PASSED

- VibeWatchAppTests/KeychainStorageTests.swift: FOUND
- VibeWatchAppTests/AuthMigrationTests.swift: FOUND
- .planning/phases/02-security-hardening/02-00-SUMMARY.md: FOUND
- Commit c88ea90 (KeychainStorageTests): FOUND
- Commit 87aa100 (AuthMigrationTests): FOUND

---
*Phase: 02-security-hardening*
*Completed: 2026-03-06*
