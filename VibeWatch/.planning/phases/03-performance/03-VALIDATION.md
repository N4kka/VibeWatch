---
phase: 3
slug: performance
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-21
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
| 3-01-01 | 03-01 | 0 | PERF-01, PERF-02, PERF-03, PERF-04 | unit stub | quick run | ❌ W0 | ⬜ pending |
| 3-01-02 | 03-01 | 1 | PERF-01 | unit | quick run | ❌ W0 | ⬜ pending |
| 3-01-03 | 03-01 | 1 | PERF-02 | unit | quick run | ❌ W0 | ⬜ pending |
| 3-02-01 | 03-02 | 1 | PERF-03 | unit | quick run | ❌ W0 | ⬜ pending |
| 3-03-01 | 03-03 | 2 | PERF-04 | unit | quick run | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `VibeWatchAppTests/PerformanceTests.swift` — stubs for PERF-01, PERF-02, PERF-03, PERF-04
  - `testLoadCachedContentSyncReturnsTrueWithData` (PERF-01)
  - `testLoadCachedContentSyncReturnsFalseWhenEmpty` (PERF-01)
  - `testCarouselGeneratedOncePerLaunch` (PERF-02)
  - `testConcurrentReadDoesNotBlockWrite` (PERF-03)
  - `testDiscoveryLoadsFromCacheBeforeNetwork` (PERF-04)
  - `testClipsLoadsFromCacheBeforeNetwork` (PERF-04)
- [ ] Mock `ClipQuotaService` returning `isProUser = true` for PERF-04 movie/TV detail tests
- [ ] In-memory SQLite fixture (seed `personalized_discovery` table) for PERF-01 tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cold launch Discovery screen appears in <500ms | PERF-01 | Requires device timing — simulator timing unreliable | Kill app, launch, measure time-to-first-content with Xcode Time Profiler |
| Movie/TV detail loads cached poster/title before network | PERF-04 | Requires network throttling to observe cache-first | Enable Network Link Conditioner (Very Bad Network), open detail screen, verify cached title appears immediately |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
