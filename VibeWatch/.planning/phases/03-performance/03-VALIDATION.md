---
phase: 3
slug: performance
status: audited
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-21
audited: 2026-05-07
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Xcode 15) |
| **Config file** | No separate config — scheme TestAction in `VibeWatchApp.xcodeproj` |
| **Quick run command** | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibeWatchAppTests/PerformanceTests` |
| **Full suite command** | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'` |
| **Estimated runtime** | ~120 seconds (full suite) |

---

## Sampling Rate

- **After every task commit:** Run `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibeWatchAppTests/PerformanceTests`
- **After every plan wave:** Run `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16'`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds (PerformanceTests subset)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 3-00-01 | 03-00 | 0 | PERF-01, PERF-02, PERF-03, PERF-04 | unit stub | quick run | ✅ | ✅ green |
| 3-01-01 | 03-01 | 1 | PERF-01 | unit | quick run | ✅ | ✅ green |
| 3-01-02 | 03-01 | 1 | PERF-02 | unit | quick run | ✅ | ✅ green |
| 3-02-01 | 03-02 | 1 | PERF-03 | unit | quick run | ✅ | ✅ green |
| 3-03-01 | 03-03 | 2 | PERF-04 | structural + manual | n/a (XCTSkip) | ✅ | ⚠️ flaky |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky (XCTSkip — structural assertions run, integration path manual)*

---

## Wave 0 Requirements

- [x] `VibeWatchAppTests/PerformanceTests.swift` — stubs for PERF-01, PERF-02, PERF-03, PERF-04 (created in Plan 03-00, commit a4fad0f)
  - `testLoadCachedContentSyncReturnsTrueWithData` (PERF-01) ✅
  - `testLoadCachedContentSyncReturnsFalseWhenEmpty` (PERF-01) ✅
  - `testCarouselGeneratedOncePerLaunch` (PERF-02) ✅
  - `testConcurrentReadDoesNotBlockWrite` (PERF-03) ✅
  - `testDiscoveryLoadsFromCacheBeforeNetwork` (PERF-04) ✅ (structural + XCTSkip)
  - `testClipsLoadsFromCacheBeforeNetwork` (PERF-04) ✅ (structural + XCTSkip)
- [x] In-memory SQLite fixture for PERF-01 tests — implemented via `refreshCacheState()` + explicit `DELETE/INSERT` pattern (commit 4dd1806); accepted deviation from mock-fixture approach
- [~] Mock `ClipQuotaService` for PERF-04 detail tests — not implemented; accepted architectural limitation (`memoryCache` private, `DatabaseClipsService` requires full app bootstrap); XCTSkip approach used per plan spec

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cold launch Discovery screen appears in <500ms | PERF-01 | Requires device timing — simulator timing unreliable | Kill app, launch, measure time-to-first-content with Xcode Time Profiler |
| Movie/TV detail loads cached poster/title before network | PERF-04 | Requires network throttling to observe cache-first | Enable Network Link Conditioner (Very Bad Network), open detail screen, verify cached title appears immediately |
| Discovery cache-first path (full integration) | PERF-04 | `DiscoveryPersonalizationService.memoryCache` is `private`; cannot seed via `@testable import` | Cold launch after prior session with personalized content; verify carousels appear before network completes |
| Clips cache-first path (full integration) | PERF-04 | `DatabaseClipsService.fetchPersonalizedClips()` requires `UserPreferenceManager` + `UserEngagementTracker` in known state — not achievable without full app bootstrap | Kill app, reopen, confirm clips appear before YouTube API response |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 60s
- [x] `nyquist_compliant: true` set in frontmatter — PERF-04 structural assertions DO run before XCTSkip; integration path is documented in Manual-Only

**Approval:** audited 2026-05-07

---

## Validation Audit 2026-05-07

| Metric | Count |
|--------|-------|
| Tasks audited | 5 |
| Gaps found | 0 (MISSING) |
| COVERED (automated GREEN) | 4 tasks (PERF-01 ×2, PERF-02, PERF-03) |
| PARTIAL (structural + XCTSkip) | 1 task (PERF-04) |
| Manual-only items | 4 |
| New test files generated | 0 |

All PERF-01/02/03 tests automated and GREEN. PERF-04 uses structural assertions + `XCTSkip` per accepted plan spec — integration path documented in Manual-Only. No new gaps introduced; VALIDATION.md promoted from draft to audited.
