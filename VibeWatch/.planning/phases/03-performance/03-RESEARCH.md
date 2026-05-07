# Phase 3: Performance - Research

**Researched:** 2026-04-21
**Domain:** iOS app launch performance, SQLite concurrency (WAL mode), Swift GCD/async patterns, SwiftUI cache-first data loading
**Confidence:** HIGH

---

## Summary

Phase 3 addresses four tightly coupled performance requirements in an offline-first SwiftUI/SQLite iOS app. The codebase already has the right high-level intent (cache-first, WAL mode enabled, in-memory cache in `DiscoveryPersonalizationService`) but has three concrete defects that block the 500ms goal.

**Defect 1 — `loadCachedContentSync()` is too shallow.** It checks `ContentCacheManager.cachedClips`, but `ContentCacheManager.init()` populates `cachedClips` via an async `Task`, so on first call the array is always empty. The `getCachedDiscoveryMovies()` guard also returns `nil` on a stale-day check, so on the first cold start of a new day the function returns `false`, and the app falls through to the full `preloadContent()` path. The function does not read `personalized_discovery` from SQLite at all.

**Defect 2 — Two `generatePersonalizedCarousels` call sites execute sequentially per launch.** `preloadContent()` (lines ~421-432 in `VibeWatchApp.swift`) calls it unconditionally as the tail of preload. `refreshContentInBackground()` (lines ~330-340) calls it inside a `.utility` `Task`. If the cache has cold data, both branches can fire the same session: `refreshContentInBackground` runs in the cached path, `preloadContent` runs in the no-cache path. Neither path is guarded by a launch-scoped boolean. The `DiscoveryPersonalizationService.memoryCache` guard prevents *expensive* double work, but the call overhead (DB read + main actor hop) still occurs twice.

**Defect 3 — All SQLite reads serialize through a single `dbQueue`.** `execute()` uses `dbQueue.sync` and `queryRaw()` uses `dbQueue.async`. With WAL mode already enabled, SQLite supports concurrent readers against a writer. The current architecture funnels every query — read or write — through one serial `DispatchQueue`. Adding a dedicated reader queue (`SQLITE_OPEN_READONLY` connection or `dbQueue` configured for concurrent reads) removes this bottleneck for Discovery, MovieDetail, TVDetail, and Clips cold starts.

**Defect 4 — Movie/TV detail cache-first is PRO-only.** `loadMovieDetails()` and `loadTVShowDetails()` both wrap the cache read in `if isProUser`. Free users always hit the network on open. PERF-04 requires "cached content appears instantly" for those three screens — the requirement does not say PRO-only. The planner must decide whether PERF-04 means: (a) read-through cache for all users, or (b) accept the PRO restriction and confirm the requirement is satisfied for PRO only. This is the one open question below.

**Primary recommendation:** Fix the three clear defects (launch-path boolean guard, single-queue reads, `loadCachedContentSync` logic) and resolve the PRO-scope question before starting implementation.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PERF-01 | App launch reaches usable Discovery screen in under 500ms from cache — verify and enforce the instant-launch path in `AppState.loadCachedContentSync()` | `loadCachedContentSync()` identified as broken for two cases: stale-day cache returns nil, `cachedClips` is always empty at sync call time. Fix requires reading `personalized_discovery` from SQLite synchronously OR correcting the staleness gate. |
| PERF-02 | Personalization carousels generated once per cold start — deduplicate the two `generatePersonalizedCarousels` call sites | Both `preloadContent()` and `refreshContentInBackground()` call `generatePersonalizedCarousels`. Need a single launch-scoped `hasGeneratedCarousels: Bool` flag on `AppState` or the service, guarded at call time. |
| PERF-03 | SQLite supports concurrent reads — add a dedicated reader queue alongside the existing writer queue, using WAL mode (already enabled) | `SQLiteService` has one serial `dbQueue`. WAL mode is already enabled. Need a second read-only connection + reader `DispatchQueue`. Standard pattern for SQLite WAL: open a second `db` handle with `SQLITE_OPEN_READONLY \| SQLITE_OPEN_NOMUTEX` for concurrent reads. |
| PERF-04 | Discovery, Movie/TV detail, and Clips screens show cached content instantly — audit each screen's data load path and ensure cache-first reads with background refresh | Discovery: correct, cache-first via `DiscoveryPersonalizationService.memoryCache` → DB. Clips: correct via `ClipsRepository` → `DatabaseClipsService` → `ContentCacheManager`. MovieDetail/TVDetail: cache-first is PRO-only — scope question must be resolved. |
</phase_requirements>

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SQLite3 (system) | iOS 17+ built-in | Local persistence via raw C API | Already in use; no dependency to add |
| Foundation `DispatchQueue` | Swift stdlib | Thread management for SQLite queues | Already in use; no new import |
| Swift `async/await` + `Task` | Swift 5.9 | Async coordination, priority management | Already in use throughout |
| `@MainActor` | Swift 5.9 | Main-thread state isolation | Already in use for all ViewModels |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| XCTest | Xcode 15+ | Unit tests for launch path and queue behaviour | Existing test infrastructure; use `.measureBlock` for timing assertions |
| `os.Logger` | iOS 14+ | Structured logging for performance instrumentation | Already defined as `Logger` wrapper in codebase |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Second SQLite connection for reads | GRDB.swift | GRDB has better WAL concurrency API, but introducing a new dependency to a stable app is too risky for a v1 stabilisation milestone |
| `DispatchQueue` concurrency | Swift actors | Migrating `SQLiteService` to a full actor would be the right long-term move but touches every call site; DispatchQueue split is minimal-risk |

**Installation:** No new packages required.

---

## Architecture Patterns

### Current `SQLiteService` Queue Architecture
```
SQLiteService.dbQueue  (serial, QoS: .userInitiated)
    execute()          → dbQueue.sync  ← blocks calling thread
    queryRaw()         → dbQueue.async ← suspends calling task
    insert/update/delete → all route through queryRaw or execute
```

### Target Architecture for PERF-03
```
SQLiteService.writerQueue  (serial, QoS: .userInitiated)  ← writes only
SQLiteService.readerQueue  (concurrent, QoS: .userInitiated) ← reads only
    execute()  → writerQueue.sync    (DDL, INSERT, UPDATE, DELETE)
    queryRaw() → readerQueue.async   (SELECT only)
```

WAL mode is already `PRAGMA journal_mode = WAL`. With WAL, readers never block writers and writers never block readers when using separate connection handles. The correct implementation opens a **second** `OpaquePointer` (read-only connection) because SQLite's WAL reader/writer non-blocking guarantee applies across separate connections, not across the same connection with concurrent queue dispatch.

### Pattern 1: Second Read-Only SQLite Connection
**What:** Open a second `db` handle for reads with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`. All `queryRaw` calls use the reader handle; all `execute` calls use the writer handle.
**When to use:** Any time concurrent read/write is needed with WAL mode.
**Example:**
```swift
// Source: SQLite documentation — WAL concurrent access
private var readerDb: OpaquePointer?
private let readerQueue = DispatchQueue(
    label: "com.vibewatch.sqlite.reader",
    attributes: .concurrent,
    qos: .userInitiated
)

private func openReaderConnection() {
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_SHAREDCACHE
    if sqlite3_open_v2(dbPath, &readerDb, flags, nil) != SQLITE_OK {
        Logger.error("[SQLite] Failed to open reader connection")
    }
}

// queryRaw uses readerDb + readerQueue
// execute uses db (writer) + dbQueue (serial)
```

### Pattern 2: Launch-scoped Carousel Generation Guard
**What:** A single `Bool` on `AppState` (or `DiscoveryPersonalizationService`) that is set to `true` on first successful `generatePersonalizedCarousels` call and checked before each subsequent call site.
**When to use:** Any async work that must run exactly once per cold start.
**Example:**
```swift
// In AppState (or DiscoveryPersonalizationService)
private var carouselsGeneratedThisLaunch = false

// Both call sites check before calling:
guard !carouselsGeneratedThisLaunch else { return }
carouselsGeneratedThisLaunch = true
let profile = await UserPreferenceManager.shared.aggregatePreferences()
_ = try? await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
    userProfile: profile, forceRefresh: false
)
```

### Pattern 3: Corrected `loadCachedContentSync()`
**What:** Read the `personalized_discovery` table synchronously at init to determine if cached data exists, instead of relying on `ContentCacheManager.cachedClips` (which is populated asynchronously).
**When to use:** AppState.init() — must be synchronous, no async allowed.

The simplest fix that avoids a new synchronous SQLite call in init is to check whether the `personalizedDiscovery` SQLite table has any rows by reading a scalar `COUNT(*)` synchronously using `dbQueue.sync`. This is safe in `init()` because `SQLiteService.shared` is a singleton initialised before `AppState`.

```swift
// Source: existing SQLiteService.execute() pattern — synchronous queue access
private func loadCachedContentSync() -> Bool {
    // Use SQLiteService's synchronous dbQueue.sync for a fast COUNT check
    var hasPersonalizedCache = false
    SQLiteService.shared.dbQueue.sync {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(SQLiteService.shared.db,
           "SELECT COUNT(*) FROM personalized_discovery LIMIT 1",
           -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                hasPersonalizedCache = sqlite3_column_int(stmt, 0) > 0
            }
            sqlite3_finalize(stmt)
        }
    }
    let hasInitialData = UserDefaults.standard.bool(forKey: "initialDataPopulated")
    return hasPersonalizedCache || hasInitialData
}
```

Note: `dbQueue` is currently `private`. It must be made `internal` or a public helper method exposed for this pattern. The alternative is adding a `hasCachedPersonalizedContent() -> Bool` synchronous method directly on `SQLiteService`.

### Anti-Patterns to Avoid
- **Calling `queryRaw` from `init()`**: It is async and cannot be awaited from a synchronous init. Use `dbQueue.sync` with raw `sqlite3_*` calls for the one synchronous check.
- **Opening the reader connection before WAL mode is confirmed active**: Always confirm `PRAGMA journal_mode = WAL` returns `wal` before using concurrent connections. The writer's `openDatabase()` already does this.
- **Task priority inversion**: The carousel `.utility` Task in `refreshContentInBackground()` should remain `.utility` — do not promote it to `.userInitiated` or it will compete with UI updates.
- **Minimum loading time anti-pattern**: `ClipsViewModel.ensureMinimumLoadingTime()` enforces a 2-second minimum. This is intentional UX policy but is worth flagging — it means Clips will never show in under 2 seconds on first session load regardless of cache state. PERF-04 for Clips requires cache-first reads; the 2s minimum is a separate UX choice. The planner should note this does not conflict with PERF-04 (which says "cached content before network refresh", not "under 500ms").

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WAL concurrent reads | Custom file-level locking | Second `sqlite3_open_v2` with `SQLITE_OPEN_READONLY` | SQLite WAL guarantees are only at the connection level |
| Launch timing measurement | Custom `Date()` subtraction in production code | `XCTestCase.measure {}` block in tests | Reproducible, not affected by debug overhead |
| Deduplication via Combine | Publisher merge + dedup operator | Simple `Bool` flag | Zero dependencies, trivially testable |

---

## Common Pitfalls

### Pitfall 1: Accessing `dbQueue` from `@MainActor` context
**What goes wrong:** `dbQueue.sync` called from the main thread deadlocks if any code on `dbQueue` attempts to dispatch back to main synchronously.
**Why it happens:** Serial queue + main thread = deadlock when re-entrant.
**How to avoid:** The synchronous read in `loadCachedContentSync()` must never call back to main. Raw `sqlite3_*` calls are safe — they are pure C with no dispatch.
**Warning signs:** App hangs on launch with no crash log.

### Pitfall 2: Reader connection opened before WAL mode is set
**What goes wrong:** If a read-only connection is opened before `PRAGMA journal_mode = WAL` is executed on the writer, the reader may use rollback journal mode, negating the concurrency benefit.
**Why it happens:** Initialization ordering — both connections open in `init()`.
**How to avoid:** `openReaderConnection()` must be called after `execute("PRAGMA journal_mode = WAL")` in `openDatabase()`.

### Pitfall 3: `carouselsGeneratedThisLaunch` flag on wrong object
**What goes wrong:** If the flag is on `DiscoveryPersonalizationService`, it survives across `AppState` re-creation in tests, causing false positives.
**Why it happens:** `DiscoveryPersonalizationService.shared` is a singleton; `AppState()` is created fresh per test.
**How to avoid:** Put the flag on `AppState`, not on the service. Or expose a `resetForTesting()` method on the service.

### Pitfall 4: `loadCachedContentSync()` using `dbQueue` before SQLiteService is ready
**What goes wrong:** `AppState.init()` calls `loadCachedContentSync()` which tries `SQLiteService.shared.dbQueue.sync`, but `SQLiteService.shared` lazy-initialises on first access, which calls `openDatabase()` (another `dbQueue.sync`) — potential nested sync if not careful.
**Why it happens:** Lazy singleton initialisation inside the body of `dbQueue.sync`.
**How to avoid:** Ensure `SQLiteService.shared` is accessed before the `dbQueue.sync` block so the singleton is fully initialised. Access `SQLiteService.shared` once outside the block, capture in a local variable, then enter `dbQueue.sync`. (This is actually safe since `SQLiteService.init()` itself calls `dbQueue.sync` during `createTables()` / `runMigrations()` — but the re-entrancy must be verified. The safe approach: use `dbQueue.async` in a new method `hasCachedPersonalizedContent()` that returns via a completion, or just expose a pre-computed property that is set after init.)

The **safest design for the sync check** is a new stored property on `SQLiteService` that is set synchronously during `runMigrations()` or after `createTables()`:
```swift
// In SQLiteService, set after init:
private(set) var hasPersonalizedDiscoveryCache: Bool = false

// Called at end of createTables():
private func checkInitialCacheState() {
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM personalized_discovery LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
        hasPersonalizedDiscoveryCache = sqlite3_step(stmt) == SQLITE_ROW
            && sqlite3_column_int(stmt, 0) > 0
        sqlite3_finalize(stmt)
    }
}
```
Then `loadCachedContentSync()` reads `SQLiteService.shared.hasPersonalizedDiscoveryCache` — no queue re-entry at all.

### Pitfall 5: PRO-gate on detail cache creates misleading PERF-04 test
**What goes wrong:** A test written as a free user will never see cached detail content, so the test will always pass (network path) or always fail (no cache), not testing the actual requirement.
**Why it happens:** `loadMovieDetails()` / `loadTVShowDetails()` early-return to network for non-PRO users.
**How to avoid:** Test with a mocked `ClipQuotaService` that returns `isProUser = true`, or resolve the PRO-scope question and update the implementation.

---

## Code Examples

Verified patterns from existing codebase:

### Synchronous SQLite read (existing pattern in `execute()`)
```swift
// Source: SQLiteService.swift:430 — dbQueue.sync already used for execute()
@discardableResult
func execute(_ sql: String, parameters: [Any] = []) -> Bool {
    var success = false
    dbQueue.sync { [weak self] in
        guard let self = self else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        // ...
    }
    return success
}
```

### Existing WAL mode setup (confirmed enabled)
```swift
// Source: SQLiteService.swift:147
execute("PRAGMA journal_mode = WAL")
```

### Existing carousel cache hit path (confirmed working)
```swift
// Source: DiscoveryPersonalizationService.swift:58-61
// LEVEL 1: MEMORY CACHE (Instant)
if !forceRefresh, let cached = memoryCache {
    Logger.info("[DiscoveryPersonalizationService] Loaded from memory cache (instant)")
    return cached
}
// LEVEL 2: DATABASE CACHE (Fast)
if !forceRefresh {
    if let cached = try await loadFromCache(userId: userProfile.userId) {
        self.memoryCache = cached
        return cached
    }
}
```

### Existing `refreshContentInBackground` carousel call (the second call site)
```swift
// Source: VibeWatchApp.swift:330-340
Task(priority: .utility) {
    let profile = await UserPreferenceManager.shared.aggregatePreferences()
    do {
        _ = try await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
            userProfile: profile,
            forceRefresh: false
        )
    } catch { ... }
}
```

### Existing `preloadContent` carousel call (the first call site)
```swift
// Source: VibeWatchApp.swift:421-432
let profile = await UserPreferenceManager.shared.aggregatePreferences()
do {
    _ = try await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
        userProfile: profile,
        forceRefresh: false
    )
} catch { ... }
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single SQLite connection | WAL mode enabled on single connection | Prior to Phase 3 | Necessary but not sufficient — still one serial queue |
| `UserDefaults` for cache metadata | SQLite `app_metadata` table | Prior to Phase 3 | Cache read/write is consistent; metadata accessible in sync |
| Full preload on every launch | Cache-first path with `loadCachedContentSync()` | Phase 4 (commented as such) | Intent is correct, implementation has edge cases listed above |
| Inline carousel generation per VM load | `DiscoveryPersonalizationService` with memory+DB cache | Prior to Phase 3 | Good design; duplicate call sites are the remaining issue |

**Deprecated/outdated:**
- `UserDefaults`-based cache keys (`legacyCachedMoviesKey`, `legacyCachedTVShowsKey` etc.) in `ContentCacheManager`: legacy migration path exists, but these keys should never be written to going forward. Already handled by existing migration code.

---

## Open Questions

1. **Does PERF-04 apply to free users for Movie/TV detail screens?**
   - What we know: `loadMovieDetails()` / `loadTVShowDetails()` only read from `DetailCacheService` for PRO users. Free users always go to network.
   - What's unclear: The PERF-04 requirement says "Discovery, Movie/TV detail, and Clips screens show cached content instantly" without a PRO qualifier. The `DetailCacheService` does not gate *writing* the cache on PRO status — it only gates *reading*. The tables exist for all users.
   - Recommendation: The planner should treat PERF-04 as PRO-only for Movie/TV detail (consistent with existing app behaviour) unless the product decision changes. The Discovery and Clips paths work for all users and are the higher-traffic paths.

2. **Is `dbQueue` accessible outside `SQLiteService` for the sync count check?**
   - What we know: `dbQueue` is `private` in `SQLiteService`. `execute()` is `public` and uses `dbQueue.sync`.
   - What's unclear: Can we safely add a new synchronous `hasCachedPersonalizedContent() -> Bool` method to `SQLiteService` without re-entrancy risk?
   - Recommendation: Yes — add the method directly on `SQLiteService`. It will call `dbQueue.sync` just like `execute()` does. No re-entrancy risk as long as it is not called from within the queue itself. `AppState.init()` runs on MainActor, which is external to `dbQueue`.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Xcode 15) |
| Config file | No separate config — scheme TestAction in `VibeWatchApp.xcodeproj` |
| Quick run command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibeWatchAppTests/PerformanceTests` |
| Full suite command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PERF-01 | `loadCachedContentSync()` returns `true` when `personalized_discovery` table has rows | unit | `xcodebuild test ... -only-testing:VibeWatchAppTests/PerformanceTests/testLoadCachedContentSyncReturnsTrueWithData` | ❌ Wave 0 |
| PERF-01 | `loadCachedContentSync()` returns `false` when table is empty | unit | `xcodebuild test ... -only-testing:VibeWatchAppTests/PerformanceTests/testLoadCachedContentSyncReturnsFalseWhenEmpty` | ❌ Wave 0 |
| PERF-02 | `generatePersonalizedCarousels` called at most once per `AppState` init regardless of cache state | unit | `xcodebuild test ... -only-testing:VibeWatchAppTests/PerformanceTests/testCarouselGeneratedOncePerLaunch` | ❌ Wave 0 |
| PERF-03 | `SQLiteService` reader queue does not block during concurrent write | unit | `xcodebuild test ... -only-testing:VibeWatchAppTests/PerformanceTests/testConcurrentReadDoesNotBlockWrite` | ❌ Wave 0 |
| PERF-04 | Discovery screen populates carousels before any network call when DB cache exists | unit | `xcodebuild test ... -only-testing:VibeWatchAppTests/PerformanceTests/testDiscoveryLoadsFromCacheBeforeNetwork` | ❌ Wave 0 |
| PERF-04 | Clips screen populates clips before any network call when DB has rows | unit | `xcodebuild test ... -only-testing:VibeWatchAppTests/PerformanceTests/testClipsLoadsFromCacheBeforeNetwork` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibeWatchAppTests/PerformanceTests`
- **Per wave merge:** Full suite: `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `VibeWatchAppTests/PerformanceTests.swift` — covers PERF-01, PERF-02, PERF-03, PERF-04
- [ ] Needs mock `ClipQuotaService` returning `isProUser = true` for PERF-04 movie/TV detail tests
- [ ] Needs in-memory SQLite fixture (seed `personalized_discovery` table) for PERF-01 tests

---

## Sources

### Primary (HIGH confidence)
- Direct source code audit: `VibeWatchApp/App/VibeWatchApp.swift` (AppState, preloadContent, refreshContentInBackground, loadCachedContentSync)
- Direct source code audit: `VibeWatchApp/Core/Database/SQLiteService.swift` (execute, queryRaw, dbQueue, WAL setup)
- Direct source code audit: `VibeWatchApp/Core/Services/DiscoveryPersonalizationService.swift` (memoryCache, generatePersonalizedCarousels, two-level cache)
- Direct source code audit: `VibeWatchApp/Features/Discovery/ViewModels/MovieDetailViewModel.swift` (TVShowDetailViewModel included, PRO-gated cache read)
- Direct source code audit: `VibeWatchApp/Features/Clips/ViewModels/ClipsViewModel.swift` (ensureMinimumLoadingTime)
- Direct source code audit: `VibeWatchApp/Core/Services/ClipsRepository.swift` (DB-first fetch)
- Direct source code audit: `VibeWatchApp/Core/Services/ContentCacheManager.swift` (async init, cachedClips populated via Task)
- SQLite documentation: WAL mode concurrent reader/writer requires separate connection handles — `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md` — PERF-01 to PERF-04 requirement text
- `.planning/ROADMAP.md` — Phase 3 plan breakdown (03-01, 03-02, 03-03)
- `.planning/STATE.md` — decision: "Single SQLite writer + concurrent readers (WAL mode already enabled)"

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies; all existing APIs confirmed in source
- Architecture: HIGH — defects identified via direct code inspection, not inference
- Pitfalls: HIGH — re-entrancy and PRO-gate issues traced to specific lines of code
- PERF-04 PRO scope: MEDIUM — requirement text is ambiguous; recommendation is conservative

**Research date:** 2026-04-21
**Valid until:** 2026-05-21 (stable platform, low churn — 30 days is safe)
