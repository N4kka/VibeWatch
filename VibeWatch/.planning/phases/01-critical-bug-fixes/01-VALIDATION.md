---
phase: 1
slug: critical-bug-fixes
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-05
audited: 2026-05-07
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
| 1-01-01 | 01 | 0 | BUG-01 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/ClipCommentServiceTests` | ✅ | ✅ green |
| 1-01-02 | 01 | 0 | BUG-01 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/DatabaseMigrationTests` | ✅ | ✅ green |
| 1-02-01 | 02 | 0 | BUG-02 | integration | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/SyncEngineTests/testUnblockSchemaErrorOperations` | ✅ | ✅ green |
| 1-02-02 | 02 | manual | BUG-02 | manual | Simulator + Supabase: add blocked row, call unblock method, verify status → completed | N/A | ✅ verified |
| 1-03-01 | 03 | 0 | BUG-03 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/AppNavigationManagerTests` | ✅ | ✅ green |
| 1-03-02 | 03 | manual | BUG-03 | manual | Kill app, tap notification in Notification Center, verify MovieDetailView opens | N/A | ✅ verified |
| 1-04-01 | 04 | 0 | BUG-04 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing:VibeWatchAppTests/AnalyticsInsightsTests` | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `VibeWatchAppTests/ClipCommentServiceTests.swift` — verify `commentRPCDisabled` property no longer exists on `ClipCommentService` (BUG-01)
- [x] `VibeWatchAppTests/DatabaseMigrationTests.swift` — verify `DatabaseMigrationManager` version increments to 3 and `updated_at` column exists in `clip_comments` after migration (BUG-01)
- [x] Add `testUnblockSchemaErrorOperations()` to existing `VibeWatchAppTests/SyncEngineTests.swift` — insert row with `status = 'blocked'` and `last_error LIKE '%PGRST205%'`, call `unblockAndRetryBlockedOperations()`, assert `status = 'pending'` (BUG-02)
- [x] `VibeWatchAppTests/AppNavigationManagerTests.swift` — unit test `handle(userInfo:)` with valid movie/TV payloads and missing `media_id` fallback (BUG-03)
- [x] `VibeWatchAppTests/AnalyticsInsightsTests.swift` — seed `user_clip_history` with known genre IDs, assert expected mood distribution keys; assert empty state returns non-nil `moodAnalysis` with placeholder (BUG-04)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| SyncEngine blocked op succeeds end-to-end after schema fix | BUG-02 | Requires live Supabase connection; can't be mocked meaningfully | Add a blocked row to `sync_outbox`, update Supabase schema, launch app, verify row status becomes `completed` |
| Cold-launch notification tap navigates to content | BUG-03 | Requires physical device or simulator with push notification entitlements | Kill app, tap notification in iOS Notification Center, verify `MovieDetailView` or `TVDetailView` opens with correct content |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 120s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** 2026-05-07

---

## Validation Audit 2026-05-07

| Metric | Count |
|--------|-------|
| Gaps found | 0 |
| Resolved | 0 |
| Escalated | 0 |
| Manual-only | 2 |

All 5 automated test files confirmed on disk and GREEN per VERIFICATION.md (verified 2026-03-06, re-verified 2026-05-07). No new tests were needed.
