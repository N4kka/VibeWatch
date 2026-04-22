# Phase 4: Code Quality - Research

**Researched:** 2026-04-22
**Domain:** Swift logging migration + XCTest unit test rewrite
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| QUAL-01 | All 212 `print()` calls replaced with `Logger` — no raw print statements in production code paths | Logger enum already exists with `#if DEBUG` guards; 186 non-Logger/non-test print() calls confirmed across 28 files |
| QUAL-02 | `MultiDeviceSyncTests.swift` updated to use `SyncEngine` and `ConflictResolver` APIs — test compiles and passes | SyncEngine.shared + ConflictResolver() exist; MultiDeviceSyncTests uses non-existent SyncManager; proper test infrastructure exists in VibeWatchAppTests/ |
</phase_requirements>

---

## Summary

Phase 4 has two fully independent tasks: replace raw `print()` calls with the existing `Logger` enum, and rewrite `MultiDeviceSyncTests.swift` to use the real `SyncEngine` and `ConflictResolver` APIs.

**QUAL-01** is a mechanical substitution. The project already has a production-ready `Logger` enum at `VibeWatchApp/Core/Utilities/Logger.swift` with `debug`, `info`, `warning`, and `error` methods, all wrapped in `#if DEBUG`. The enum's own 8 internal `print()` calls are intentional (they are the implementation). The remaining 186 `print()` calls across 28 production Swift files are raw and must be replaced. The REQUIREMENTS.md cites 212 total; the delta is the 8 in Logger.swift + 17 in MultiDeviceSyncTests.swift + rounding. Logger.swift itself must NOT be touched for QUAL-01.

**QUAL-02** is a rewrite, not a fix. `MultiDeviceSyncTests.swift` is in the main app target (`VibeWatchApp/Tests/`) and references a `SyncManager` class that does not exist anywhere in the codebase. It also uses non-existent types: `UnifiedPreferenceRecord`, `WatchlistItemRecord`, `ReactionRecord` as passed to `syncManager.resolveConflict(local:remote:)`, and operations like `syncManager.queueSync(operation:)` and `syncManager.processSyncOutbox()`. The real APIs are on `SyncEngine` (for queuing/syncing) and `ConflictResolver` (for conflict resolution). A well-structured `ConflictResolverTests.swift` and `SyncEngineTests.swift` already exist in the proper test target (`VibeWatchAppTests/`) and demonstrate the correct API usage patterns. The fix is to rewrite `MultiDeviceSyncTests.swift` to call `ConflictResolver().resolve(table:local:remote:)` and `SyncEngine.shared.queueOperation(...)` using the same patterns as the existing working tests.

**Primary recommendation:** Do QUAL-01 as a single mechanical pass over 28 files using sed or multi-file find/replace, then do QUAL-02 as a full rewrite of `MultiDeviceSyncTests.swift` mirroring the patterns already proven in `ConflictResolverTests.swift` and `SyncEngineTests.swift`.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `Logger` enum (project) | project-internal | `#if DEBUG`-guarded logging replacing raw `print()` | Already in codebase; zero dependencies |
| `XCTest` | iOS SDK | Unit test framework for QUAL-02 rewrite | Already used by all 11 passing test files |
| `SyncEngine` | project-internal | Queuing and sync operations | Real replacement for fictional `SyncManager` |
| `ConflictResolver` | project-internal | Conflict resolution strategies | Real replacement for fictional `syncManager.resolveConflict` |

### Logger API (confirmed from source)
| Method | Signature | Use Case |
|--------|-----------|----------|
| `Logger.debug` | `(_ message: String, file: String = #file, line: Int = #line)` | Verbose trace — init steps, state transitions |
| `Logger.info` | `(_ message: String)` | Routine operation outcomes |
| `Logger.warning` | `(_ message: String)` | Recoverable unexpected conditions |
| `Logger.error` | `(_ message: String, error: Error? = nil)` | Failures requiring attention |
| `Logger.log` | `(_ message: String, prefix: String = "📱")` | General app-level messages with emoji prefix |
| `Logger.log` | `(_ message: String, category: String)` | Tagged category logging |

**Installation:** No install required — Logger.swift is already in the project.

---

## Architecture Patterns

### QUAL-01: print() Replacement Strategy

**File distribution (28 files, 186 calls):**

| File | Count | Dominant Logger Level |
|------|----|----------------------|
| `App/VibeWatchApp.swift` | 36 | `Logger.info` / `Logger.debug` |
| `Core/Database/DatabaseMigrationService.swift` | 15 | `Logger.info` / `Logger.error` |
| `Features/Profile/Views/SettingsView.swift` | 14 | `Logger.info` / `Logger.debug` |
| `Features/Clips/Views/ProPaywallView.swift` | 12 | `Logger.info` / `Logger.debug` |
| `Core/Utilities/PlatformDeepLinkHelper.swift` | 11 | `Logger.info` / `Logger.debug` |
| `Core/Network/StreamingAvailabilityService.swift` | 11 | `Logger.info` / `Logger.error` |
| `App/MainTabView.swift` | 11 | `Logger.debug` |
| `App/AppDelegate.swift` | 11 | `Logger.info` / `Logger.debug` |
| `Shared/Components/CommentsListView.swift` | 10 | `Logger.debug` |
| (19 more files) | 55 | mixed |

**Level selection heuristic:**
- `print("✅ ...")` — success outcome → `Logger.info`
- `print("❌ ...")` — error/failure → `Logger.error`
- `print("⚠️ ...")` — warning → `Logger.warning`
- `print("🔍 ...")`, `print("📦 ...")`, `print("🔄 ...")` — trace/state → `Logger.debug`
- `print("📱 ...")`, `print("🗄️ ...")` — app-level events → `Logger.info` or `Logger.log`

**IMPORTANT: Logger.swift internal print() calls are NOT replaced.** The 8 `print()` calls inside `Logger.swift` implement the Logger itself. They are already inside `#if DEBUG` guards. Do not touch them.

**IMPORTANT: MultiDeviceSyncTests.swift print() calls.** The 17 `print()` calls in `MultiDeviceSyncTests.swift` are inside test helper/assertion methods. They will be removed as part of the QUAL-02 rewrite (the file is being fully rewritten). Do not replace them in place during QUAL-01.

### QUAL-02: MultiDeviceSyncTests Rewrite

**Root cause:** `MultiDeviceSyncTests.swift` was written against a fictional `SyncManager` API that was never implemented. The app uses `SyncEngine` (not `SyncManager`) and `ConflictResolver` (not `syncManager.resolveConflict`).

**Non-existent types/methods in current file:**
- `SyncManager` — does not exist anywhere in the codebase
- `SyncManager.shared` — does not exist
- `syncManager.resolveConflict(local:remote:)` — does not exist
- `syncManager.queueSync(operation:)` — does not exist
- `syncManager.processSyncOutbox()` — does not exist
- `UnifiedPreferenceRecord(preferenceId:score:scoreFromClips:...)` — does not exist
- `WatchlistItemRecord(mediaId:updatedAt:deletedAt:)` — does not exist
- `ReactionRecord(mediaId:reactionType:updatedAt:deletedAt:)` — does not exist (a private inner struct exists in `MovieReactionService.swift` but is not the same type)
- `PreferenceSignal(category:id:name:weight:source:)` — the struct exists in `UserProfile.swift` but `SyncOperationType.updatePreferences([signal])` does not exist

**Real API (verified from source):**

```swift
// ConflictResolver — use directly
let resolver = ConflictResolver()
let result: ResolvedRecord = resolver.resolve(
    table: "movie_reactions",   // or "lists", "user_gamification", etc.
    local: [String: Any],
    remote: [String: Any]
)
// result.strategyUsed: ConflictStrategy
// result.wasModified: Bool
// result.source: ResolvedRecord.RecordSource (.local / .remote / .merged)
// result.record: [String: Any]

// SyncEngine — queueOperation
try await SyncEngine.shared.queueOperation(
    table: "some_table",
    operationType: "INSERT",    // or "UPDATE", "UPSERT", "DELETE"
    recordId: UUID().uuidString,
    payload: [String: Any],
    dependsOn: Int?             // nil for no dependency
)

// SyncEngine — state inspection
SyncEngine.shared.pendingOperationsCount  // Int (published)
SyncEngine.shared.isSyncing               // Bool (published, @MainActor)
await SyncEngine.shared.resetBlockedOperations()
```

**The rewrite covers the same conflict resolution scenarios** — preference merge, watchlist union, deletion priority, reaction last-write-wins — but uses `ConflictResolver().resolve(table:local:remote:)` with raw `[String: Any]` dictionaries, matching the patterns in the existing `ConflictResolverTests.swift`.

**File placement:** `MultiDeviceSyncTests.swift` is in `VibeWatchApp/Tests/` (inside the main app target per pbxproj). It is compiled into `VibeWatchApp`, not into `VibeWatchAppTests`. The rewrite must use `@testable import VibeWatchApp` and `import XCTest`, with `final class MultiDeviceSyncTests: XCTestCase`. This matches the existing file structure.

### Anti-Patterns to Avoid
- **Replacing Logger.swift's internal print() calls:** Those 8 calls implement the logger — leave them alone.
- **Using `SyncManager` in the rewrite:** That type does not exist. Use `SyncEngine.shared`.
- **Mapping emoji to wrong Logger level:** `✅` → info (not debug), `❌` → error (not warning).
- **Keeping `print()` calls in test file:** QUAL-02 rewrites the file entirely; there is no print() migration step for that file.
- **Moving MultiDeviceSyncTests.swift to VibeWatchAppTests/:** The file is in the main target by project structure. Leave the location unchanged.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| `#if DEBUG` logging | Custom log enum | `Logger` (already exists) | Already sanitizes sensitive data, already in production use |
| Conflict resolution in tests | Custom test strategies | `ConflictResolver().resolve(table:local:remote:)` | Five strategies already implemented and tested |
| Sync queue assertions | Custom outbox reader | `SQLiteService.shared.queryRaw(...)` | Already used in `SyncEngineTests.swift` helpers |

---

## Common Pitfalls

### Pitfall 1: Logger.swift's print() calls counted in the 212
**What goes wrong:** Developer replaces Logger.swift's internal `print()` calls thinking they are raw print statements.
**Why it happens:** The grep finds all print() including Logger.swift's own implementation.
**How to avoid:** Explicitly exclude Logger.swift from the replacement pass. Its 8 print() calls are `#if DEBUG`-guarded and are the correct final state.
**Warning signs:** If Logger.debug/info/warning/error methods suddenly produce no output in DEBUG builds.

### Pitfall 2: MultiDeviceSyncTests print() calls replaced instead of file being rewritten
**What goes wrong:** Replacing the 17 print() calls in MultiDeviceSyncTests.swift without also fixing the compile errors.
**Why it happens:** QUAL-01 and QUAL-02 are treated as independent find-replace passes.
**How to avoid:** QUAL-02 rewrites MultiDeviceSyncTests.swift entirely. The print() calls in that file are not part of QUAL-01 scope.

### Pitfall 3: Wrong Logger level choice creates misleading logs
**What goes wrong:** Success messages logged as `Logger.error`, error paths logged as `Logger.debug`.
**Why it happens:** Developer doesn't map emoji conventions.
**How to avoid:** Follow the emoji heuristic: ✅ → info, ❌ → error, ⚠️ → warning, 🔍/🔄/📦 → debug.

### Pitfall 4: MultiDeviceSyncTests rewrite keeps synchronous helpers that don't compile
**What goes wrong:** `cleanTestData()` and similar helpers reference non-existent types.
**Why it happens:** The rewrite keeps the structure but only swaps the types.
**How to avoid:** Mirror the helper patterns from `SyncEngineTests.swift` which use `SQLiteService.shared.queryRaw` directly.

### Pitfall 5: `@MainActor` isolation on `SyncEngine.shared`
**What goes wrong:** Accessing `SyncEngine.shared.isSyncing` or calling methods without `@MainActor` context causes compiler errors or runtime actor violations.
**Why it happens:** `SyncEngine` is `@MainActor` class.
**How to avoid:** Wrap assertions in `await MainActor.run { ... }` as shown in `SyncEngineTests.swift`'s `testIsSyncingFlag()`.

---

## Code Examples

Verified patterns from project source:

### Replacing a print() call (QUAL-01)
```swift
// BEFORE
print("✅ [Migration] Already migrated")
print("❌ [Migration] Migration failed after retries: \(error)")
print("⚠️ [Migration] Supabase not configured, skipping clips migration")
print("📦 [Migration] Fetched \(clips.count) clips from Supabase")

// AFTER
Logger.info("[Migration] Already migrated")
Logger.error("[Migration] Migration failed after retries: \(error)")
Logger.warning("[Migration] Supabase not configured, skipping clips migration")
Logger.debug("[Migration] Fetched \(clips.count) clips from Supabase")
```

### Conflict resolution test (QUAL-02 pattern — from ConflictResolverTests.swift)
```swift
// Source: VibeWatchAppTests/ConflictResolverTests.swift
func testLastWriteWinsStrategy_LocalNewer() {
    let local: [String: Any] = [
        "id": "reaction-1",
        "reaction_type": "love",
        "updated_at": "2024-01-02T15:00:00Z"
    ]
    let remote: [String: Any] = [
        "id": "reaction-1",
        "reaction_type": "like",
        "updated_at": "2024-01-01T10:00:00Z"
    ]
    let result = resolver.resolve(table: "movie_reactions", local: local, remote: remote)
    XCTAssertEqual(result.strategyUsed, .lastWriteWins)
    XCTAssertEqual(result.source, .local)
    XCTAssertEqual(result.record["reaction_type"] as? String, "love")
}
```

### Preference weighted merge test (QUAL-02 pattern — direct analog to testPreferenceMergeConflict)
```swift
// The MultiDeviceSyncTests scenario maps to: table = "unified_user_preferences"
// local = [String: Any] dict with score/source fields
// remote = [String: Any] dict with score/source fields
// ConflictResolver uses .weightedMerge strategy for "unified_user_preferences"
let local: [String: Any] = [
    "id": "pref-genre-878",
    "score": 10.0,
    "score_from_clips": 10.0,
    "score_from_discovery": 0.0,
    "interaction_count": 1,
    "updated_at": "2024-01-01T10:00:00Z"
]
let remote: [String: Any] = [
    "id": "pref-genre-878",
    "score": 15.0,
    "score_from_clips": 0.0,
    "score_from_discovery": 15.0,
    "interaction_count": 1,
    "updated_at": "2024-01-01T10:00:01Z"
]
let resolver = ConflictResolver()
let result = resolver.resolve(table: "unified_user_preferences", local: local, remote: remote)
XCTAssertEqual(result.strategyUsed, .weightedMerge)
// score_from_clips max = 10.0, score_from_discovery max = 15.0
XCTAssertEqual(result.record["score_from_clips"] as? Double, 10.0)
XCTAssertEqual(result.record["score_from_discovery"] as? Double, 15.0)
```

### Watchlist union merge (QUAL-02 pattern)
```swift
// table = "list_items" uses .union strategy
let local: [String: Any] = ["id": "item-123", "media_id": 123, "deleted_at": NSNull(), "updated_at": "..."]
let remote: [String: Any] = ["id": "item-123", "media_id": 123, "deleted_at": NSNull(), "updated_at": "..."]
let result = resolver.resolve(table: "list_items", local: local, remote: remote)
XCTAssertNil(result.record["deleted_at"] as? String, "Item should not be deleted")
```

### Watchlist deletion priority (QUAL-02 pattern)
```swift
// If local is NOT deleted and remote IS deleted → union strategy keeps local (non-deleted wins)
// If local IS deleted and remote is NOT deleted → union strategy keeps remote (non-deleted wins)
// This is the INVERSE of testWatchlistDeletionPriority which tests deletion priority:
// the current ConflictResolver's .union strategy for list_items prefers NON-deleted records
let deletedLocal: [String: Any] = ["id": "item-456", "deleted_at": "2024-01-01T10:00:00Z", "updated_at": "..."]
let keptRemote: [String: Any] = ["id": "item-456", "deleted_at": NSNull(), "updated_at": "..."]
let result = resolver.resolve(table: "list_items", local: deletedLocal, remote: keptRemote)
// union: remote is not deleted → source = .remote (non-deleted wins)
XCTAssertEqual(result.source, .remote)
```

### SyncEngine state inspection in tests (from SyncEngineTests.swift)
```swift
// Source: VibeWatchAppTests/SyncEngineTests.swift
let isSyncing = await MainActor.run { syncEngine.isSyncing }
XCTAssertFalse(isSyncing, "Should not be syncing initially")
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| Raw `print()` in production | `Logger.info/debug/warning/error` with `#if DEBUG` | Release builds produce zero output |
| `SyncManager` (never existed) | `SyncEngine.shared` | Tests actually compile |
| `syncManager.resolveConflict(local:remote:)` | `ConflictResolver().resolve(table:local:remote:)` | Tests cover real conflict logic |

---

## Open Questions

1. **Deletion priority semantics in QUAL-02**
   - What we know: `ConflictResolver.union` for `list_items` prefers non-deleted (local non-deleted beats remote deleted; remote non-deleted beats local deleted)
   - What's unclear: The original `testWatchlistDeletionPriority` test asserts deletion wins — but the actual `ConflictResolver` implementation preserves non-deleted. The rewrite should test what the code actually does, not what the old fictional test expected.
   - Recommendation: Document the real behavior in the rewritten test.

2. **MultiDeviceSyncTests.swift location (main target vs test target)**
   - What we know: The file is in `VibeWatchApp/Tests/` and compiled into the main `VibeWatchApp` target per pbxproj.
   - What's unclear: Whether running `xcodebuild test -scheme VibeWatchApp` actually executes it, or only `VibeWatchAppTests` tests run.
   - Recommendation: Keep it in-place for now (the pbxproj already has it registered). If the test doesn't execute under the test scheme, move it to `VibeWatchAppTests/` — that is where all other passing tests live.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (iOS SDK) |
| Config file | Xcode scheme — no separate config file |
| Quick run command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibeWatchAppTests 2>&1 \| grep -E "passed\|failed\|error"` |
| Full suite command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| grep -E "passed\|failed\|error"` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| QUAL-01 | Zero print() in non-Logger production files | grep audit | `grep -r "print(" VibeWatchApp --include="*.swift" \| grep -v "Logger.swift" \| grep -v "MultiDeviceSyncTests.swift"` | ✅ (audit, not a test file) |
| QUAL-02 | MultiDeviceSyncTests compiles and all cases pass | unit | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| grep "MultiDeviceSyncTests"` | ✅ (rewrite of existing file) |

### Sampling Rate
- **Per task commit:** grep audit for QUAL-01; build check for QUAL-02
- **Per wave merge:** Full test suite
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
None — existing test infrastructure covers all phase requirements. QUAL-01 verification is a grep audit (no test file needed). QUAL-02 rewrites an existing file in the existing `VibeWatchApp` target.

---

## Sources

### Primary (HIGH confidence)
- `VibeWatchApp/Core/Utilities/Logger.swift` — Logger API, all 6 methods confirmed, #if DEBUG guards confirmed
- `VibeWatchApp/Infrastructure/Sync/SyncEngine.swift` — `queueOperation`, `performFullSync`, `pushPendingChanges`, `pullFromRemote`, `resetBlockedOperations`, `@MainActor` class confirmed
- `VibeWatchApp/Infrastructure/Sync/ConflictResolver.swift` — `resolve(table:local:remote:)`, `ResolvedRecord`, `ConflictStrategy`, all 5 strategies confirmed
- `VibeWatchAppTests/ConflictResolverTests.swift` — proven test patterns for ConflictResolver API
- `VibeWatchAppTests/SyncEngineTests.swift` — proven test patterns for SyncEngine API, @MainActor pattern confirmed

### Secondary (MEDIUM confidence)
- `VibeWatchApp.xcodeproj/project.pbxproj` — `MultiDeviceSyncTests.swift` confirmed in main `VibeWatchApp` target, not test target

### Tertiary (LOW confidence)
- Line count of 212 print() in REQUIREMENTS.md vs 186+17+8=211 found via grep — within 1 of stated count (minor discrepancy likely from a commented-out print or count rounding in requirements)

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Logger, SyncEngine, ConflictResolver all verified from source
- Architecture: HIGH — file lists, call counts, API signatures all confirmed from live codebase
- Pitfalls: HIGH — root causes verified against actual source (SyncManager not found, Logger internal prints confirmed)

**Research date:** 2026-04-22
**Valid until:** 2026-05-22 (stable codebase — Logger API and SyncEngine API are unlikely to change)
