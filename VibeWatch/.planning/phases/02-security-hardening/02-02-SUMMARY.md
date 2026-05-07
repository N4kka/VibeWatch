---
phase: 02-security-hardening
plan: "02"
subsystem: auth
tags: [ios-security, keychain, security-framework, supabase, userdatamigration, tdd, unit-tests]

# Dependency graph
requires:
  - phase: 02-security-hardening/02-00
    provides: TDD RED baseline — KeychainStorageTests (6 stubs) and AuthMigrationTests (3 stubs) registered in test target
  - phase: 01-critical-bug-fixes
    provides: stable app build baseline
provides:
  - "KeychainStorage.swift: AuthLocalStorage adapter using Security.framework with kSecAttrAccessibleAfterFirstUnlock"
  - "AuthService.init() runs migrateUserDefaultsToKeychain() before setupClient() — existing users silently migrated on first launch"
  - "SupabaseClient initialized with AuthOptions(storage: keychainStorage) — SDK session encrypted in Keychain"
  - "saveCachedAuthState / loadCachedAuthState / clearCachedAuthState all use Keychain — no auth tokens in UserDefaults"
  - "KeychainStorageTests: 6 tests, all GREEN"
  - "AuthMigrationTests: 3 tests, all GREEN (success, failure/re-login, idempotency)"
affects:
  - future auth-related plans that read/write session tokens
  - app reinstall / backup / restore behavior (Keychain items not backed up unless configured)

# Tech tracking
tech-stack:
  added:
    - Security.framework (iOS system framework — no new SPM dependency)
  patterns:
    - Delete-then-add Keychain store pattern (SecItemDelete + SecItemAdd) for idempotent overwrites
    - kSecAttrAccessibleAfterFirstUnlock for background-task-accessible encrypted storage
    - nonisolated static migration overload accepting injected stores as TDD seam
    - 1-byte Bool encoding for Keychain (Data([value ? 1 : 0])) — avoids NSKeyedArchiver dependency

key-files:
  created:
    - VibeWatchApp/Core/Services/KeychainStorage.swift
  modified:
    - VibeWatchApp/Core/Services/AuthService.swift
    - VibeWatchAppTests/AuthMigrationTests.swift

key-decisions:
  - "SupabaseClientOptions.AuthOptions(storage:) constructor used instead of options.auth.storage = — storage is a let constant in supabase-swift 2.38.1"
  - "_migrateUserDefaultsToKeychain declared nonisolated static — required for synchronous call from XCTest without @MainActor isolation"
  - "Bool cached as 1-byte Data([byte]) in Keychain — simple, no encoder dependency, decode with isAuthData.first != 0"
  - "Migration failure clears both UserDefaults keys and attempts Keychain removes — no stale plaintext tokens remain regardless of outcome"
  - "import Auth added to AuthMigrationTests.swift — AuthLocalStorage from Auth module not visible without explicit import (supabase-swift @_exported import not visible through @testable import)"

patterns-established:
  - "nonisolated static migration overload: accepts injected UserDefaults + AuthLocalStorage stores for testability without main-actor singleton"
  - "Keychain delete-then-add: always SecItemDelete first (ignoring status), then SecItemAdd — handles update case without SecItemUpdate"
  - "KeychainStorage service namespace: Bundle.main.bundleIdentifier ?? 'com.vibewatch.auth' — test instances use unique service strings to isolate Keychain state"

requirements-completed: [SEC-02]

# Metrics
duration: 25min
completed: 2026-03-06
---

# Phase 2 Plan 02: Keychain Auth Storage Summary

**iOS Keychain adapter (KeychainStorage.swift) wired into AuthService as SDK session storage and manual cache, with silent one-time UserDefaults-to-Keychain migration — auth tokens now encrypted at rest using Security.framework kSecAttrAccessibleAfterFirstUnlock**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-03-06T09:47:00Z
- **Completed:** 2026-03-06T11:01:00Z
- **Tasks:** 2
- **Files modified:** 3 (1 created, 2 modified)

## Accomplishments
- Created `KeychainStorage.swift` implementing `AuthLocalStorage` protocol from supabase-swift — store/retrieve/remove using Security.framework with `kSecAttrAccessibleAfterFirstUnlock`
- Updated `AuthService` with 4 changes: `keychainStorage` property, `_migrateUserDefaultsToKeychain()`, `SupabaseClientOptions.AuthOptions(storage:)` wiring, and Keychain-backed save/load/clear
- All 6 `KeychainStorageTests` pass GREEN (store/retrieve, overwrite, remove, remove-missing, retrieve-missing, accessibility round-trip)
- All 3 `AuthMigrationTests` pass GREEN (success path, failure/re-login path, idempotency)
- No UserDefaults references remain for `auth_cached_user` or `auth_cached_is_authenticated` in save/load/clear code paths

## Task Commits

Each task was committed atomically:

1. **Task 1: Create KeychainStorage.swift and make RED tests GREEN** - `2656ad4` (feat)
2. **Task 2: Update AuthService with Keychain wiring and migration** - `24feb83` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `VibeWatchApp/Core/Services/KeychainStorage.swift` — AuthLocalStorage adapter: store (delete+add), retrieve (nil on errSecItemNotFound), remove (idempotent), KeychainError enum
- `VibeWatchApp/Core/Services/AuthService.swift` — keychainStorage property; _migrateUserDefaultsToKeychain(from:to:) nonisolated static; AuthOptions(storage:) in setupClient(); Keychain-backed loadCachedAuthState/saveCachedAuthState/clearCachedAuthState
- `VibeWatchAppTests/AuthMigrationTests.swift` — Added `import Auth` (Rule 1 fix: AuthLocalStorage not visible through @testable import without explicit Auth module import)

## Decisions Made
- `SupabaseClientOptions.AuthOptions(storage: keychainStorage)` constructor pattern required because `AuthOptions.storage` is a `let` constant in supabase-swift 2.38.1 — the `var options.auth.storage =` pattern from research docs would not compile
- `_migrateUserDefaultsToKeychain` declared `nonisolated static` to allow synchronous call from XCTest without `@MainActor` isolation requirement
- Bool stored as `Data([byte ? 1 : 0])` in Keychain — avoids NSKeyedArchiver/JSONEncoder for a single boolean value
- Migration failure path clears BOTH UserDefaults and Keychain to prevent stale plaintext — user re-login is the safe recovery path

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added `import Auth` to AuthMigrationTests.swift**
- **Found during:** Task 1 (first test run after creating KeychainStorage.swift)
- **Issue:** `AuthLocalStorage` type referenced in `MockFailingKeychain: AuthLocalStorage` was not visible through `@testable import VibeWatchApp` alone — the Supabase module's `@_exported import Auth` is not re-exported through `@testable import`
- **Fix:** Added `import Auth` to AuthMigrationTests.swift
- **Files modified:** `VibeWatchAppTests/AuthMigrationTests.swift`
- **Verification:** Build succeeded, AuthMigrationTests compiled correctly
- **Committed in:** `2656ad4` (Task 1 commit)

**2. [Rule 1 - Bug] Used SupabaseClientOptions.AuthOptions(storage:) constructor instead of var/set pattern**
- **Found during:** Task 2 (setupClient() implementation)
- **Issue:** `options.auth.storage = keychainStorage` failed to compile — `storage` is a `let` constant on `AuthOptions` which is a `let` on `SupabaseClientOptions` in supabase-swift 2.38.1
- **Fix:** Changed to `SupabaseClientOptions(auth: SupabaseClientOptions.AuthOptions(storage: keychainStorage))`
- **Files modified:** `VibeWatchApp/Core/Services/AuthService.swift`
- **Verification:** Build succeeded, all tests GREEN
- **Committed in:** `24feb83` (Task 2 commit)

**3. [Rule 1 - Bug] Declared _migrateUserDefaultsToKeychain as nonisolated static**
- **Found during:** Task 2 (test compilation)
- **Issue:** AuthMigrationTests.swift calls the method synchronously from a non-isolated XCTest context — `@MainActor`-inherited static method cannot be called without await or actor isolation
- **Fix:** Added `nonisolated` modifier to the static method
- **Files modified:** `VibeWatchApp/Core/Services/AuthService.swift`
- **Verification:** AuthMigrationTests compiled and all 3 tests GREEN
- **Committed in:** `24feb83` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (3 Rule 1 bugs — compile errors preventing test execution)
**Impact on plan:** All auto-fixes were necessary for correctness and compilation. No scope creep. The SupabaseClientOptions API mismatch and nonisolated requirement were both foreseeable from the supabase-swift source code once inspected.

## Issues Encountered
- `xcodebuild test` with `platform=iOS Simulator,name=iPhone 16` failed (Xcode 26 simulator name mismatch, pre-existing from plan 02-01). Resolved by using simulator UDID `id=601C4430-6213-49E3-8A4D-3564B2B57E2A` (same workaround from 02-01 Summary)
- Full test suite reports 13 pre-existing failures in `ConflictResolverTests`, `SyncEngineTests`, and `SyncStateMachineTests` — all in the sync layer, unrelated to auth/Keychain. These were present before this plan's changes and are out of scope.

## User Setup Required
None — Keychain storage is a device-local operation. No external service configuration required.

## Next Phase Readiness
- SEC-02 complete. Auth tokens are encrypted at rest in iOS Keychain.
- Migration is in place for existing users — silent, idempotent, failure-safe.
- Background sync tasks can read tokens after device reboot before first unlock (kSecAttrAccessibleAfterFirstUnlock).
- Pre-existing test failures in SyncEngine/ConflictResolver are unrelated blockers for any future sync-layer plans.

---
*Phase: 02-security-hardening*
*Completed: 2026-03-06*

## Self-Check: PASSED

- VibeWatchApp/Core/Services/KeychainStorage.swift: FOUND
- VibeWatchApp/Core/Services/AuthService.swift: FOUND
- .planning/phases/02-security-hardening/02-02-SUMMARY.md: FOUND
- Commit 2656ad4 (Task 1 — KeychainStorage.swift): FOUND
- Commit 24feb83 (Task 2 — AuthService Keychain wiring): FOUND
