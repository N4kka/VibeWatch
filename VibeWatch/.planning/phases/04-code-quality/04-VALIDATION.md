---
phase: 4
slug: code-quality
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-22
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (iOS SDK) |
| **Config file** | Xcode scheme — no separate config file |
| **Quick run command** | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibeWatchAppTests 2>&1 \| grep -E "passed\|failed\|error"` |
| **Full suite command** | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| grep -E "passed\|failed\|error"` |
| **Estimated runtime** | ~120 seconds (full suite) |

---

## Sampling Rate

- **After every task commit:** `grep -r "print(" VibeWatchApp --include="*.swift" | grep -v "Logger.swift" | grep -v "MultiDeviceSyncTests.swift"` (QUAL-01); build check (QUAL-02)
- **After every plan wave:** Full test suite
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~5 seconds (grep audit), ~120 seconds (full suite)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 4-01-01 | 04-01 | 1 | QUAL-01 | grep audit | `grep -r "print(" VibeWatchApp --include="*.swift" \| grep -v "Logger.swift"` | ✅ (audit) | ⬜ pending |
| 4-02-01 | 04-02 | 1 | QUAL-02 | unit | `xcodebuild test ... \| grep "MultiDeviceSyncTests"` | ✅ (rewrite) | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

None — existing test infrastructure covers all phase requirements. QUAL-01 verification is a grep audit (no new test file needed). QUAL-02 rewrites the existing `MultiDeviceSyncTests.swift` against real APIs.

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Release build produces zero console print() output | QUAL-01 | #if DEBUG guards mean grep audit is sufficient; release build suppresses Debug-wrapped output automatically | Run grep audit; confirm zero matches in non-Logger production files |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
