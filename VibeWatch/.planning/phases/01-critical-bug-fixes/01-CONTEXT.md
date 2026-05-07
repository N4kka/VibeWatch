# Phase 1: Critical Bug Fixes - Context

**Gathered:** 2026-03-05
**Status:** Ready for planning

<domain>
## Phase Boundary

Eliminate four user-visible data failures: comments silently failing to sync, SyncEngine operations permanently stuck in a blocked state, push notification taps doing nothing, and the Analytics Dashboard mood section always empty. No new features — only these four specific bug fixes. Success is measured by the four success criteria in ROADMAP.md.

</domain>

<decisions>
## Implementation Decisions

### commentRPCDisabled flag (BUG-01)
- Remove the `commentRPCDisabled` flag entirely — delete the disable mechanism and the early-exit guard at ClipCommentService lines 16-17 and 760-762
- Do NOT implement any runtime RPC-disable mechanism as a replacement
- Comments that silently failed while the flag was true are not retried — those are lost (acceptable for pre-production)
- SQL migration: add `updated_at` column to `clips_comments` table with `DEFAULT NOW()` so existing rows are backfilled with current timestamp automatically

### SyncEngine PGRST205 recovery (BUG-02)
- Recovery trigger: on every app launch, attempt to push all operations currently in `blocked` state
- If a retried blocked operation fails again (schema still wrong): re-block it, wait for next launch — same cycle
- Scope of retry: both originally-blocked operations AND any operations queued while the engine was blocked (retry all pending outbox items)
- UX: completely silent — no toast, no status indicator when blocked ops retry or succeed

### Notification tap routing (BUG-03)
- Destination: directly to MovieDetailView or TVDetailView for the referenced content
- Same behavior whether app is killed (cold launch) or backgrounded — tap always deep-links to content
- Fallback if content cannot be found (TMDB ID missing): silently navigate to Discovery tab, no error alert
- Implementation goes in SmartNotificationService.handleNotificationTap via AppNavigationManager

### Mood analysis — Analytics Dashboard (BUG-04)
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

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AppNavigationManager`: exists for programmatic navigation — notification routing should use this to deep-link into MovieDetailView/TVDetailView
- `DatabaseMigrationManager`: version 2 — the `updated_at` column migration should be added as version 3 here; `SQLiteMigrations.swift` may need a corresponding entry
- `ErrorHandler.shared` + toast system: exists but should NOT be used for sync recovery (silent per decision)
- `SyncEngine.syncOutbox` / `sync_outbox` SQLite table: blocked operations are stored here with a `status` field; on-launch retry should query for `status = 'blocked'` and reset to pending

### Established Patterns
- SyncEngine already has exponential backoff state machine (`SyncStateMachine`) — on-launch unblock should feed into this rather than bypass it
- `AppState` triggers sync on launch (`SyncEngine.pullFromRemote()`) — on-launch retry of blocked ops should be wired at the same point
- `AnalyticsInsightsService.generateUserStatistics()` already constructs a `UserStatistics` struct — mood analysis fills the `moodAnalysis` field that is currently hardcoded nil

### Integration Points
- `ClipCommentService.swift` lines 16-17 and 760-762: where flag is declared and set — remove both
- `SyncEngine.swift` lines 464-480 (PGRST205 blocking) and 797-808 (no recovery path): where the unblock-on-launch logic connects
- `SmartNotificationService.swift:1163`: the stub `handleNotificationTap` to implement
- `AnalyticsInsightsService.swift:48`: the hardcoded `moodAnalysis: nil` to replace

</code_context>

<specifics>
## Specific Ideas

- The commentRPCDisabled fix is primarily a backend schema change (SQL migration) + dead code removal on the client; the migration is the critical dependency
- For notification routing, cold-launch handling means the navigation must be deferred until after `AppState` finishes initialization (watch for `isPreloading == false` or similar gate)
- Mood analysis should reuse genre data that already flows through `UserPreferenceManager` — the genre name map there (duplicated from `PersonalizedClipsService`) is the right source

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 01-critical-bug-fixes*
*Context gathered: 2026-03-05*
