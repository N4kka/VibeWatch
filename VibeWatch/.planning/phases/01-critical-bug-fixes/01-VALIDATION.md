---
phase: 1
slug: critical-bug-fixes
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-05
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Apple native) |
| **Config file** | `VibeWatchApp.xcodeproj` test target `VibeWatchAppTests` |
| **Quick run command** | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/SyncEngineTests -destination 'platform=iOS Simulator,name=iPhone 16'` |
| **Full suite command** | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'` |
| **Estimated runtime** | ~60–120 seconds (simulator boot + tests) |

---

## Sampling Rate

- **After every task commit:** Run the single relevant test class for the bug being fixed
- **After every plan wave:** Run full suite (`xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'`)
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 1-01-01 | 01 | 0 | BUG-01 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/ClipCommentServiceTests` | ❌ W0 | ⬜ pending |
| 1-01-02 | 01 | 0 | BUG-01 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/DatabaseMigrationTests` | ❌ W0 | ⬜ pending |
| 1-02-01 | 02 | 0 | BUG-02 | integration | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/SyncEngineTests/testUnblockSchemaErrorOperations` | ❌ W0 | ⬜ pending |
| 1-02-02 | 02 | manual | BUG-02 | manual | Simulator + Supabase: add blocked row, call unblock method, verify status → completed | N/A | ⬜ pending |
| 1-03-01 | 03 | 0 | BUG-03 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/AppNavigationManagerTests` | ❌ W0 | ⬜ pending |
| 1-03-02 | 03 | manual | BUG-03 | manual | Kill app, tap notification in Notification Center, verify MovieDetailView opens | N/A | ⬜ pending |
| 1-04-01 | 04 | 0 | BUG-04 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/AnalyticsInsightsTests` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `VibeWatchAppTests/ClipCommentServiceTests.swift` — verify `commentRPCDisabled` property no longer exists on `ClipCommentService` (BUG-01)
- [ ] `VibeWatchAppTests/DatabaseMigrationTests.swift` — verify `DatabaseMigrationManager` version increments to 3 and `updated_at` column exists in `clip_comments` after migration (BUG-01)
- [ ] Add `testUnblockSchemaErrorOperations()` to existing `VibeWatchAppTests/SyncEngineTests.swift` — insert row with `status = 'blocked'` and `last_error LIKE '%PGRST205%'`, call `unblockAndRetryBlockedOperations()`, assert `status = 'pending'` (BUG-02)
- [ ] `VibeWatchAppTests/AppNavigationManagerTests.swift` — unit test `handle(userInfo:)` with valid movie/TV payloads and missing `media_id` fallback (BUG-03)
- [ ] `VibeWatchAppTests/AnalyticsInsightsTests.swift` — seed `user_clip_history` with known genre IDs, assert expected mood distribution keys; assert empty state returns non-nil `moodAnalysis` with placeholder (BUG-04)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| SyncEngine blocked op succeeds end-to-end after schema fix | BUG-02 | Requires live Supabase connection; can't be mocked meaningfully | Add a blocked row to `sync_outbox`, update Supabase schema, launch app, verify row status becomes `completed` |
| Cold-launch notification tap navigates to content | BUG-03 | Requires physical device or simulator with push notification entitlements | Kill app, tap notification in iOS Notification Center, verify `MovieDetailView` or `TVDetailView` opens with correct content |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
