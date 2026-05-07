# Phase 1: Critical Bug Fixes - Research

**Researched:** 2026-03-05
**Domain:** iOS/Swift — Supabase schema migration, SyncEngine recovery, push notification deep-linking, analytics mood computation
**Confidence:** HIGH (all findings drawn from direct source code inspection)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**BUG-01 — commentRPCDisabled flag:**
- Remove the `commentRPCDisabled` flag entirely — delete the disable mechanism and the early-exit guard at ClipCommentService lines 16-17 and 760-762
- Do NOT implement any runtime RPC-disable mechanism as a replacement
- Comments that silently failed while the flag was true are not retried — those are lost (acceptable for pre-production)
- SQL migration: add `updated_at` column to `clips_comments` table with `DEFAULT NOW()` so existing rows are backfilled with current timestamp automatically

**BUG-02 — SyncEngine PGRST205 recovery:**
- Recovery trigger: on every app launch, attempt to push all operations currently in `blocked` state
- If a retried blocked operation fails again (schema still wrong): re-block it, wait for next launch — same cycle
- Scope of retry: both originally-blocked operations AND any operations queued while the engine was blocked (retry all pending outbox items)
- UX: completely silent — no toast, no status indicator when blocked ops retry or succeed

**BUG-03 — Notification tap routing:**
- Destination: directly to MovieDetailView or TVDetailView for the referenced content
- Same behavior whether app is killed (cold launch) or backgrounded — tap always deep-links to content
- Fallback if content cannot be found (TMDB ID missing): silently navigate to Discovery tab, no error alert
- Implementation goes in SmartNotificationService.handleNotificationTap via AppNavigationManager

**BUG-04 — Mood analysis:**
- Direction: implement basic mood analysis (do not remove or stub)
- Data source: genre patterns from viewing history only — no ML, deterministic mapping
- Output: 3-5 broad mood categories (e.g., Light, Adventurous, Dark, Romantic, Intense) mapped from genre IDs
- Empty state: when user has no viewing history, show a neutral "Not enough data yet" placeholder — do not return nil and hide the section

### Claude's Discretion
- Exact genre-to-mood mapping taxonomy (which genres map to which of the 3-5 moods)
- Minimum viewing history threshold before showing mood vs. placeholder
- Exact wording for the "not enough data" placeholder
- How AppNavigationManager.navigate is called from SmartNotificationService (parameter shape, async handling)
- Whether PGRST205 on-launch retry runs before or after the normal sync pull

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| BUG-01 | Fix missing `updated_at` column in Supabase `clip_comments` schema; remove `commentRPCDisabled` flag | SQL migration pattern confirmed; exact removal lines identified (ClipCommentService:16-17, 760-762); `DatabaseMigrationManager` version 3 pattern established |
| BUG-02 | Add SyncEngine on-launch recovery for PGRST205-blocked operations | `unblockSchemaErrorOperations()` helper already exists at SyncEngine:792-801 but is never called; `performFullSyncOnLaunch()` in AppState is the correct wiring point |
| BUG-03 | Implement `SmartNotificationService.handleNotificationTap` routing to MovieDetailView/TVDetailView via AppNavigationManager | `AppNavigationManager.handle(userInfo:)` is already implemented and sets `deepLinkTarget`; stub at SmartNotificationService:1158-1165 is the only gap; cold-launch deferral pattern identified |
| BUG-04 | Implement basic mood analysis in `AnalyticsInsightsService.generateUserStatistics` | `MoodAnalysis` struct already defined at line 674; `UserStatistics.moodAnalysis` is `MoodAnalysis?` (optional, non-breaking); genre map lives in `UserPreferenceManager:25-30` and is the canonical source |
</phase_requirements>

---

## Summary

This phase corrects four independent bugs, none of which require new architectural components. All four fixes operate entirely within existing patterns: modifying service internals, adding a SQL migration, wiring a call site that already exists, and implementing a deterministic computation where a nil stub currently lives.

**BUG-01** has a subtle dimension: the Supabase migration file `99999999999999_fix_clips_updated_at_and_engagement.sql` already contains `ALTER TABLE clip_comments ALTER COLUMN updated_at SET DEFAULT timezone('utc', now())` but uses a timestamp filename (`99999999999999`) that causes ordering ambiguity. The fix requires a properly-dated migration file in `supabase/supabase/migrations/` and a corresponding local `DatabaseMigrationManager` version-3 entry. The original `202512042230_clip_comments_likes.sql` already defines `updated_at timestamptz not null default now()` in the table DDL — meaning the column exists in the intended schema but was absent from the deployed database. The client-side fix is removing three lines from `ClipCommentService.swift`.

**BUG-02** reveals that `SyncEngine` already contains `unblockSchemaErrorOperations()` (lines 792-801), which performs exactly the needed SQL update (`status = 'blocked' AND last_error LIKE '%PGRST205%'` → `status = 'pending'`). This function is never called. The fix is calling it at the start of `performFullSyncOnLaunch()` in `AppState`, before the normal `pushPendingChanges()` call.

**BUG-03** shows that `AppNavigationManager` is already fully implemented (`handle(userInfo:)` parses `media_id`/`media_type` and sets `deepLinkTarget`). The stub at `SmartNotificationService:1158-1165` only needs to call `AppNavigationManager.shared.handle(userInfo: userInfo)`. The cold-launch challenge requires deferring navigation until `isPreloading == false` in `AppState`. MainTabView already uses `deepLinkTarget` observation via the `@Published` property.

**BUG-04** shows `MoodAnalysis` is a fully defined struct at `AnalyticsInsightsService:674` with `moodDistribution: [String: Int]`, `preferredMoodByTime: [String: String]`, and `emotionalJourney: [EmotionalPoint]`. The canonical genre map (`[Int: String]`) lives at `UserPreferenceManager:25-30` and must be referenced (or duplicated with a TODO) inside `AnalyticsInsightsService`. The deterministic mapping requires defining which TMDB genre IDs map to the 3-5 mood buckets.

**Primary recommendation:** Fix in plan order (BUG-01 → BUG-02 → BUG-03 → BUG-04). BUG-01 is the schema prerequisite for BUG-02 retry to actually succeed.

---

## Standard Stack

No new dependencies for this phase. All fixes use existing frameworks and patterns.

### Core (in use, no changes needed)
| Component | Version | Purpose |
|-----------|---------|---------|
| `supabase-swift` | 2.39.0 | Remote Supabase RPC calls; `PostgrestError` type used in BUG-01 catch block |
| `XCTest` | iOS SDK | Test framework for all verification tests |
| `SQLite3` | System | Local outbox operations for BUG-02 recovery |
| `UNUserNotificationCenter` | System | Notification tap delegate for BUG-03 |

### No New Dependencies
This phase is pure bug-fix work. No new SPM packages, no new frameworks.

---

## Architecture Patterns

### Existing Pattern: DatabaseMigrationManager version increment
Adding `updated_at` to `clip_comments` (local SQLite side) follows the established migration pattern:

1. Increment `latestVersion` from `2` to `3`
2. Add `Migration(version: 3, name: "clip_comments_updated_at", ...)` to the `migrations` array
3. Implement `migration3_AddClipCommentsUpdatedAt()` using `db.columnExists("clip_comments", column: "updated_at")` guard (same pattern as Migration 2 at line 135)

```swift
// Source: DatabaseMigrationManager.swift — established migration pattern
private func migration3_AddClipCommentsUpdatedAt() async throws {
    if !db.columnExists("clip_comments", column: "updated_at") {
        db.execute("ALTER TABLE clip_comments ADD COLUMN updated_at TEXT DEFAULT (datetime('now'))")
        db.execute("UPDATE clip_comments SET updated_at = datetime('now') WHERE updated_at IS NULL")
        Logger.info("[Migration 3] Added updated_at to clip_comments")
    }
}
```

### Existing Pattern: Supabase SQL migration file
New migration file must use a timestamp-based name (ISO 8601, UTC) to guarantee ordering:

```
supabase/supabase/migrations/20260305000000_add_clip_comments_updated_at.sql
```

Content:
```sql
-- BUG-01: Add updated_at to clip_comments (was defined in DDL but absent from deployed schema)
ALTER TABLE public.clip_comments
  ALTER COLUMN updated_at SET DEFAULT timezone('utc', now());

-- Backfill existing rows (DEFAULT NOW() applies only to future inserts)
UPDATE public.clip_comments
SET updated_at = now()
WHERE updated_at IS NULL;
```

Note: the original DDL in `202512042230_clip_comments_likes.sql` already defines `updated_at timestamptz not null default now()`. The issue is a deployment gap, not a design gap. The new migration uses `ALTER COLUMN ... SET DEFAULT` rather than `ADD COLUMN IF NOT EXISTS` because the column already exists in the intended schema.

### Existing Pattern: SyncEngine on-launch unblock
`performFullSyncOnLaunch()` in `AppState` (VibeWatchApp.swift:165-186) calls `SyncEngine.shared.pushPendingChanges()`. The blocked-ops recovery must run first:

```swift
// Source: VibeWatchApp.swift — performFullSyncOnLaunch, add before pushPendingChanges
// Step 1: unblock any PGRST205-blocked ops from previous sessions
await SyncEngine.shared.unblockAndRetryBlockedOperations()

// Step 2: push all pending (now including formerly-blocked ops)
await SyncEngine.shared.pushPendingChanges()
```

`SyncEngine.unblockSchemaErrorOperations()` is already private. It needs to become a public method, or a new public wrapper `unblockAndRetryBlockedOperations()` should be added to `SyncEngineProtocol`. The SQL it executes is correct as-is (lines 793-800).

### Existing Pattern: AppNavigationManager deep-link dispatch
`AppNavigationManager.handle(userInfo:)` is already implemented and sets `@Published var deepLinkTarget: DeepLinkTarget?`. The notification tap handler only needs to call it:

```swift
// Source: SmartNotificationService.swift:1158 — the stub to implement
private func handleNotificationTap(userInfo: [AnyHashable: Any]) async {
    guard let type = userInfo["type"] as? String else { return }
    Logger.info("[SmartNotificationService] Notification tapped: \(type)")

    // Dispatch to AppNavigationManager — handles media_id/media_type parsing
    // Fallback: if media_id is absent, handle(userInfo:) returns early with no navigation
    await MainActor.run {
        AppNavigationManager.shared.handle(userInfo: userInfo)
    }

    // Fallback to Discovery tab if no deep link target was resolved
    // (media_id absent or invalid media_type)
    let target = await MainActor.run { AppNavigationManager.shared.deepLinkTarget }
    if target == nil {
        NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
    }
}
```

**Cold-launch deferral:** `AppNavigationManager.deepLinkTarget` is `@Published`. MainTabView and MovieDetailView/TVDetailView must already observe it (or will after BUG-03 implementation). No explicit `isPreloading` wait is needed in the service — SwiftUI will re-evaluate `.onChange(of: navigationManager.deepLinkTarget)` once the view hierarchy is live. This is the standard pattern used for OAuth deep links in `VibeWatchApp.swift`.

### Existing Pattern: MoodAnalysis struct population
The `MoodAnalysis` struct (AnalyticsInsightsService:674-678) expects:
- `moodDistribution: [String: Int]` — mood label → count of content items
- `preferredMoodByTime: [String: String]` — time-of-day → dominant mood
- `emotionalJourney: [EmotionalPoint]` — chronological mood data points

For BUG-04's deterministic implementation, only `moodDistribution` must be non-empty. `preferredMoodByTime` and `emotionalJourney` can be empty collections (not nil) to satisfy the non-optional fields.

**Recommended genre-to-mood taxonomy** (Claude's discretion):

| Mood | TMDB Genre IDs | Genre Names |
|------|----------------|-------------|
| Light | 35, 16, 10751, 10402 | Comedy, Animation, Family, Music |
| Adventurous | 12, 14, 878, 10752, 37 | Adventure, Fantasy, Science Fiction, War, Western |
| Intense | 28, 53, 27, 80 | Action, Thriller, Horror, Crime |
| Thoughtful | 18, 99, 36, 9648 | Drama, Documentary, History, Mystery |
| Romantic | 10749, 10770 | Romance, TV Movie |

**Minimum threshold (Claude's discretion):** 5 distinct content items with genre data. Below this, return a `MoodAnalysis` with empty `moodDistribution` and the placeholder text surfaced via the view layer (not the model).

**Empty-state approach:** Return a `MoodAnalysis` instance with `moodDistribution: [:]` rather than `nil`. The Analytics Dashboard view must check `moodDistribution.isEmpty` and show the placeholder text.

**Placeholder wording (Claude's discretion):** "Not enough data yet — keep watching to see your mood profile."

### Anti-Patterns to Avoid

- **Do not add a new RPC-disable flag.** The decision is to remove the existing flag entirely. Do not replace it with a "disabled until schema is verified" variant.
- **Do not call `unblockSchemaErrorOperations()` inside `pushPendingChanges()`.** This would run on every sync push, not just on launch. The lock belongs in `performFullSyncOnLaunch()`.
- **Do not present UI for BUG-02 recovery.** `ErrorHandler.shared` and the toast system must not be used for this path. The decision is completely silent.
- **Do not sleep/poll for `isPreloading` inside `handleNotificationTap`.** The tap handler runs on `UNUserNotificationCenterDelegate` which is called after the app is in the foreground. The navigation request via `@Published deepLinkTarget` will be processed once SwiftUI re-renders.
- **Do not duplicate the genre map.** Reference `UserPreferenceManager.genreNames` or extract it to `AppConstants`. Do not add a third copy inside `AnalyticsInsightsService`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Detecting schema error from Supabase | Custom error string parsing | `PostgrestError.code == "42703"` already in `ClipCommentService:760` | The pattern is already established |
| SQL status update for blocked ops | New SQL logic | `SyncEngine.unblockSchemaErrorOperations()` at line 792 | Already correct, just never called |
| Parsing notification payload to media ID | New parsing logic | `AppNavigationManager.handle(userInfo:)` | Handles `media_id`/`movie_id` key variants, String/NSNumber coercion |
| Genre ID lookup | Hardcoded dictionary in AnalyticsInsightsService | `UserPreferenceManager.genreNames` | Canonical source; avoid third copy |
| Local SQLite `clip_comments` migration | Manual SQL in init | `DatabaseMigrationManager` version 3 entry | Ensures idempotent, versioned migration |

---

## Common Pitfalls

### Pitfall 1: Wrong Supabase migration filename
**What goes wrong:** Using a non-timestamp name (like `99999999999999_...`) causes migration ordering to break. The existing file `99999999999999_fix_clips_updated_at_and_engagement.sql` already has this problem — it cannot be relied upon to have run in the correct sequence.
**Why it happens:** Developers create fix files with placeholder timestamps.
**How to avoid:** Always use `YYYYMMDDHHmmss` format. The new migration should be named `20260305000000_add_clip_comments_updated_at.sql`.
**Warning signs:** Migration file sorts after all application-data migrations instead of at its intended position.

### Pitfall 2: Supabase schema cache not refreshed after migration
**What goes wrong:** Even after applying the migration, the Supabase PostgREST schema cache may not have refreshed. RPC calls that reference `updated_at` may still fail with PGRST205 for several minutes.
**Why it happens:** PostgREST caches the schema at startup and refreshes periodically (or on `NOTIFY pgrst, 'reload schema'`).
**How to avoid:** After applying the migration via Supabase dashboard or CLI, issue `NOTIFY pgrst, 'reload schema';` or restart the PostgREST service. Alternatively wait 5-10 minutes.
**Warning signs:** RPC still returns PGRST205 immediately after migration.

### Pitfall 3: `unblockSchemaErrorOperations()` is private — cannot be called from AppState
**What goes wrong:** `AppState` calls `SyncEngine.shared.unblockAndRetryBlockedOperations()` but the method does not exist on `SyncEngineProtocol`.
**Why it happens:** The helper is a private implementation detail.
**How to avoid:** Either make `unblockSchemaErrorOperations()` internal and call it from the same actor, or add `unblockAndRetryBlockedOperations()` to `SyncEngineProtocol` and expose a public implementation. Since `AppState` calls `SyncEngine.shared` directly (not the protocol), a `public` method on `SyncEngine` (not the protocol) is sufficient for BUG-02.
**Warning signs:** Compile error "value of type 'SyncEngine' has no member 'unblockSchemaErrorOperations'".

### Pitfall 4: `handleNotificationTap` is `private` — called from `UNUserNotificationCenterDelegate`
**What goes wrong:** The tap handler at line 1158 is `private func handleNotificationTap(...)`. It is called from the `didReceive response:` delegate method at line 1143. This is fine — it stays private. The implementation just needs to call `AppNavigationManager.shared` within the existing private method body.
**Why it happens:** N/A — no structural change needed.
**How to avoid:** Implement inside the existing private method. Do not change its visibility.

### Pitfall 5: Cold-launch navigation fires before view hierarchy is ready
**What goes wrong:** If `deepLinkTarget` is set too early (before `MainTabView` appears), the `.onChange` handler does not fire because the view is not yet in the SwiftUI hierarchy.
**Why it happens:** `UNUserNotificationCenterDelegate.didReceive` can be called during app launch, before the root view is rendered.
**How to avoid:** `AppNavigationManager.deepLinkTarget` persists until cleared. As long as `MainTabView` calls `.onAppear` or `.onChange(of: navigationManager.deepLinkTarget)` before clearing it, the navigation will fire when the view hierarchy becomes ready. The `deepLinkTarget` is not cleared automatically — only by explicit `clearDeepLinkTarget()`. The view that consumes it must call `clearDeepLinkTarget()` after navigation completes, not the service.
**Warning signs:** App opens but does not navigate on cold launch; works correctly from background.

### Pitfall 6: `MoodAnalysis.preferredMoodByTime` and `emotionalJourney` have no optional fields
**What goes wrong:** Returning `MoodAnalysis(moodDistribution: moods, preferredMoodByTime: [:], emotionalJourney: [])` compiles fine but may display an empty "by time" section in the UI if the view does not handle empty collections.
**Why it happens:** The struct was designed assuming all fields would be populated.
**How to avoid:** The Analytics Dashboard view should check `emotionalJourney.isEmpty` before rendering that subsection. BUG-04 only requires `moodDistribution` to be non-empty for a real result, or empty for the placeholder path.

### Pitfall 7: Local SQLite `clip_comments` table already has `updated_at` on some devices
**What goes wrong:** SQLite Migration 2 in `SQLiteService.swift` (line 344-367) already adds `updated_at TEXT DEFAULT (datetime('now'))` to `clip_comments`. Migration 3 in `DatabaseMigrationManager` must guard with `db.columnExists("clip_comments", column: "updated_at")` to avoid an `ALTER TABLE` error.
**Why it happens:** Two independent migration systems exist (`SQLiteService.runPersonalizationMigrations()` and `DatabaseMigrationManager.runMigrations()`). The column may already exist.
**How to avoid:** Always guard SQLite ALTER TABLE with `columnExists` check — same pattern as Migration 2 in `DatabaseMigrationManager`.

---

## Code Examples

### BUG-01: Remove commentRPCDisabled (ClipCommentService.swift)

Lines to DELETE:
```swift
// Line 17: DELETE THIS
private var commentRPCDisabled = false

// Lines 760-762: DELETE THIS catch branch body
if let pgError = error as? PostgrestError, pgError.code == "42703" || pgError.message.contains("updated_at") {
    commentRPCDisabled = true
    Logger.warning("[ClipComment] Disabling comment RPC (server schema missing column): \(pgError.message)")
}
```

Also search for any early-exit guard using `commentRPCDisabled` and delete those guard statements (lines 16-17 per CONTEXT.md — the declaration is at line 17, likely a guard at line ~16 that checks it before making the RPC call).

### BUG-02: Public unblock method on SyncEngine

```swift
// Source: SyncEngine.swift — make public, add to protocol
public func unblockAndRetryBlockedOperations() {
    unblockSchemaErrorOperations() // existing private helper
    Logger.info("[SyncEngine] Unblocked PGRST205-blocked operations for retry on launch")
}
```

Wiring in AppState (VibeWatchApp.swift `performFullSyncOnLaunch`):
```swift
// Add BEFORE the existing pushPendingChanges() call
SyncEngine.shared.unblockAndRetryBlockedOperations()
await SyncEngine.shared.pushPendingChanges()
```

### BUG-03: Notification tap implementation

```swift
// Source: SmartNotificationService.swift:1158 — replace stub body
private func handleNotificationTap(userInfo: [AnyHashable: Any]) async {
    guard let type = userInfo["type"] as? String else { return }
    Logger.info("[SmartNotificationService] Notification tapped: \(type)")

    await MainActor.run {
        let manager = AppNavigationManager.shared
        manager.handle(userInfo: userInfo)

        // Fallback: if no valid media_id/media_type in payload, go to Discovery
        if manager.deepLinkTarget == nil {
            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
        }
    }
}
```

### BUG-04: Mood analysis computation

```swift
// Source: AnalyticsInsightsService.swift — new private method
private func calculateMoodAnalysis(userId: String, timeframe: Timeframe) async -> MoodAnalysis {
    let since = timeframe.startDate

    // Fetch genre_ids from viewing history
    let sql = """
        SELECT genre_ids FROM user_clip_history
        WHERE user_id = ? AND watched_at >= ?
          AND genre_ids IS NOT NULL
    """
    let rows = (try? await sqliteService.queryRaw(sql, parameters: [userId, since.ISO8601Format()])) ?? []

    // Minimum threshold: 5 items
    guard rows.count >= 5 else {
        return MoodAnalysis(moodDistribution: [:], preferredMoodByTime: [:], emotionalJourney: [])
    }

    // Deterministic genre → mood mapping
    let genreToMood: [Int: String] = [
        35: "Light", 16: "Light", 10751: "Light", 10402: "Light",
        12: "Adventurous", 14: "Adventurous", 878: "Adventurous", 10752: "Adventurous", 37: "Adventurous",
        28: "Intense", 53: "Intense", 27: "Intense", 80: "Intense",
        18: "Thoughtful", 99: "Thoughtful", 36: "Thoughtful", 9648: "Thoughtful",
        10749: "Romantic", 10770: "Romantic"
    ]

    var moodCounts: [String: Int] = [:]
    for row in rows {
        // genre_ids stored as comma-separated string of ints
        guard let genreString = row["genre_ids"] as? String else { continue }
        let genreIds = genreString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        for genreId in genreIds {
            if let mood = genreToMood[genreId] {
                moodCounts[mood, default: 0] += 1
            }
        }
    }

    return MoodAnalysis(moodDistribution: moodCounts, preferredMoodByTime: [:], emotionalJourney: [])
}
```

Replace `moodAnalysis: nil` in `generateUserStatistics`:
```swift
async let moodStats = calculateMoodAnalysis(userId: userId, timeframe: timeframe)
// ...
moodAnalysis: await moodStats,
```

---

## State of the Art

| Old Approach | Current Approach | Context |
|--------------|------------------|---------|
| Disable RPC on first failure (commentRPCDisabled) | Remove flag entirely; backend schema is the fix | Per BUG-01 decision |
| PGRST205 → block forever | PGRST205 → block, unblock on next launch | Per BUG-02 decision |
| `handleNotificationTap` stub (no navigation) | Call `AppNavigationManager.handle(userInfo:)` | Per BUG-03 decision |
| `moodAnalysis: nil` hardcoded | Deterministic genre→mood computation | Per BUG-04 decision |

**Already exists but never called:**
- `SyncEngine.unblockSchemaErrorOperations()` — private, correct SQL, just needs a public wrapper and a call site
- `AppNavigationManager.handle(userInfo:)` — fully implemented, deep-link routing complete, just never invoked from the notification tap

---

## Open Questions

1. **Does the Supabase migration `99999999999999_fix_clips_updated_at_and_engagement.sql` need to be deleted or renamed?**
   - What we know: It was applied with a timestamp that sorts after all real migrations, creating ordering ambiguity. It contains a partially correct fix for `clip_comments`.
   - What's unclear: Whether this file has already been applied to the production Supabase instance. If it was applied, a new migration cannot re-run `ALTER COLUMN ... SET DEFAULT` without conflict.
   - Recommendation: Check Supabase dashboard migration history. If already applied, the new migration should only address any remaining gap (backfill NULLs). If not applied, delete the `99999999999999` file and create the properly-named one.

2. **How is `genre_ids` stored in `user_clip_history` SQLite table?**
   - What we know: `user_clip_history` was added in `DatabaseMigrationManager.migration2_AddMissingColumns()` (the `media_id`, `season_number`, `episode_number` columns). No `genre_ids` column was explicitly observed.
   - What's unclear: Whether `genre_ids` is stored in this table, or whether the mood analysis must join against a different table (e.g., `movie_reactions` or `user_preferences`).
   - Recommendation: During BUG-04 implementation, inspect the `user_clip_history` table schema. If `genre_ids` is absent, query from `user_preferences` genre interactions or derive genre data from the `discovery_cache` table joined on `media_id`. The computation is Claude's discretion — fallback gracefully to empty `moodDistribution` if no genre data is available.

3. **Does `MainTabView` already observe `AppNavigationManager.deepLinkTarget` and trigger navigation to MovieDetailView?**
   - What we know: `MainTabView` observes tab-jump `NotificationCenter` names. `AppNavigationManager.deepLinkTarget` is `@Published` but no `onChange` for it was found in the MainTabView grep results.
   - What's unclear: Whether `MovieDetailView`/`TVDetailView` already respond to `deepLinkTarget` changes.
   - Recommendation: During BUG-03 implementation, verify whether the `.onChange(of: navigationManager.deepLinkTarget)` handler exists in `MainTabView` or `DiscoveryView`. If absent, this handler must be added as part of BUG-03. This is within scope — it is the navigation wiring the bug fix requires.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Apple native) |
| Config file | `VibeWatchApp.xcodeproj` test target `VibeWatchAppTests` |
| Quick run command | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/SyncEngineTests -destination 'platform=iOS Simulator,name=iPhone 16'` |
| Full suite command | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BUG-01 | `commentRPCDisabled` property no longer exists on `ClipCommentService` | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/ClipCommentServiceTests` | ❌ Wave 0 |
| BUG-01 | `DatabaseMigrationManager` version increments to 3 and adds `updated_at` to `clip_comments` (SQLite) | unit/integration | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/DatabaseMigrationTests` | ❌ Wave 0 |
| BUG-02 | `SyncEngine.unblockAndRetryBlockedOperations()` resets `blocked` rows to `pending` | integration | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/SyncEngineTests/testUnblockSchemaErrorOperations` | ❌ Wave 0 (add to existing SyncEngineTests.swift) |
| BUG-02 | After unblock + push, operation succeeds when schema is present (end-to-end requires live Supabase) | manual | Simulator + Supabase: add blocked row, call method, verify status changes to `completed` | N/A — manual only |
| BUG-03 | `AppNavigationManager.handle(userInfo:)` correctly sets `deepLinkTarget` for movie payload | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/AppNavigationManagerTests` | ❌ Wave 0 |
| BUG-03 | Notification tap with missing `media_id` does NOT set `deepLinkTarget` and posts `navigateToDiscoveryTab` | unit | same `AppNavigationManagerTests` | ❌ Wave 0 |
| BUG-03 | Cold-launch notification tap navigates to correct screen | manual | Kill app, tap notification in Notification Center, verify app opens on MovieDetailView | N/A — manual only |
| BUG-04 | `calculateMoodAnalysis` returns `moodDistribution` with expected mood keys from known genre history | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/AnalyticsInsightsTests` | ❌ Wave 0 |
| BUG-04 | `calculateMoodAnalysis` returns empty `moodDistribution` (not nil) when fewer than 5 history rows | unit | same `AnalyticsInsightsTests` | ❌ Wave 0 |
| BUG-04 | `generateUserStatistics` returns `UserStatistics` with non-nil `moodAnalysis` | unit | same `AnalyticsInsightsTests` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** Run the single relevant test class for the bug being fixed
- **Per wave merge:** `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'` (full suite)
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps (new test files to create before implementation)

- [ ] `VibeWatchAppTests/ClipCommentServiceTests.swift` — covers BUG-01 flag removal; uses `ClipCommentService.shared` and Mirror introspection to verify property absence
- [ ] `VibeWatchAppTests/DatabaseMigrationTests.swift` — covers BUG-01 SQLite migration version 3; verifies `updated_at` column exists after migration runs
- [ ] Add `testUnblockSchemaErrorOperations()` to existing `VibeWatchAppTests/SyncEngineTests.swift` — inserts a row with `status = 'blocked'` and `last_error LIKE '%PGRST205%'`, calls `unblockAndRetryBlockedOperations()`, asserts `status = 'pending'` (covers BUG-02)
- [ ] `VibeWatchAppTests/AppNavigationManagerTests.swift` — covers BUG-03 payload parsing; unit tests `handle(userInfo:)` with valid and invalid payloads
- [ ] `VibeWatchAppTests/AnalyticsInsightsTests.swift` — covers BUG-04; seeds SQLite `user_clip_history` with rows containing known genre IDs, calls `calculateMoodAnalysis`, asserts expected mood distribution keys

*(Tests that require live Supabase are manual-only and excluded from automated suite.)*

---

## Sources

### Primary (HIGH confidence — direct source code inspection)
- `VibeWatchApp/Core/Services/ClipCommentService.swift` — lines 16-17 (flag declaration), 760-762 (flag set on error)
- `VibeWatchApp/Infrastructure/Sync/SyncEngine.swift` — lines 464-480 (PGRST205 blocking), 792-801 (`unblockSchemaErrorOperations` helper)
- `VibeWatchApp/App/VibeWatchApp.swift` — lines 165-186 (`performFullSyncOnLaunch`), 100-133 (launch sequence)
- `VibeWatchApp/Core/Utilities/AppNavigationManager.swift` — full implementation of `handle(userInfo:)` and `DeepLinkTarget`
- `VibeWatchApp/Core/Services/SmartNotificationService.swift` — lines 1143-1165 (delegate + stub)
- `VibeWatchApp/Core/Services/AnalyticsInsightsService.swift` — lines 43-66 (statistics generation), 616-684 (data model definitions)
- `VibeWatchApp/Core/Services/UserPreferenceManager.swift` — lines 25-30 (canonical genre name map)
- `VibeWatchApp/Core/Database/DatabaseMigrationManager.swift` — full file (migration pattern, `latestVersion = 2`)
- `supabase/supabase/migrations/202512042230_clip_comments_likes.sql` — original DDL with `updated_at` column definition
- `supabase/supabase/migrations/99999999999999_fix_clips_updated_at_and_engagement.sql` — existing (improperly named) fix migration

### Secondary (MEDIUM confidence — code inspection + pattern inference)
- `VibeWatchApp/App/MainTabView.swift` — tab navigation and `isPreloading` polling pattern
- `VibeWatchApp/Core/Database/SQLiteService.swift` — `clip_comments` local schema with `updated_at TEXT` (Migration 2)
- `VibeWatchAppTests/SyncEngineTests.swift` — established integration test pattern for `SyncEngine` + `SQLiteService`

---

## Metadata

**Confidence breakdown:**
- BUG-01 fix approach: HIGH — exact lines identified, migration file pattern confirmed, Supabase schema inspected
- BUG-02 fix approach: HIGH — `unblockSchemaErrorOperations()` found at exact location, call site in AppState confirmed
- BUG-03 fix approach: HIGH — `AppNavigationManager.handle(userInfo:)` is complete; stub location confirmed; one open question about MainTabView observer (resolvable during implementation)
- BUG-04 fix approach: HIGH for struct types; MEDIUM for genre_ids storage path (open question 2)
- Validation Architecture: HIGH — existing test infrastructure confirmed, new file locations follow established pattern

**Research date:** 2026-03-05
**Valid until:** 2026-04-05 (stable codebase; no external framework changes expected)
