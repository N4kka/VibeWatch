---
phase: 2
slug: security-hardening
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-06
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Xcode native) |
| **Config file** | `VibeWatchAppTests/Info.plist` |
| **Quick run command** | `xcodebuild build -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -5` |
| **Full suite command** | `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -40` |
| **Estimated runtime** | ~2 minutes (build check: ~30s) |

---

## Sampling Rate

- **After every task commit:** Run quick build check
- **After every plan wave:** Run full XCTest suite
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~30 seconds (build check)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 2-01-01 | 01 | 0 | SEC-01, SEC-02 | unit stubs | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/KeychainStorageTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ❌ W0 | ⬜ pending |
| 2-01-02 | 01 | 0 | SEC-02 | unit stubs | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/AuthMigrationTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ❌ W0 | ⬜ pending |
| 2-01-03 | 01 | 1 | SEC-01 | build-time | `xcodebuild build -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| grep -E 'error:|BUILD'` | N/A | ⬜ pending |
| 2-01-04 | 01 | 1 | SEC-01 | build-time | same as above | N/A | ⬜ pending |
| 2-02-01 | 02 | 2 | SEC-02 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/KeychainStorageTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ❌ W0 | ⬜ pending |
| 2-02-02 | 02 | 2 | SEC-02 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/AuthMigrationTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `VibeWatchAppTests/KeychainStorageTests.swift` — unit tests for `KeychainStorage.store/retrieve/remove` (covers SEC-02 Keychain read/write/delete on live Simulator Keychain)
- [ ] `VibeWatchAppTests/AuthMigrationTests.swift` — unit tests for migration success path, failure path (forced re-login), and idempotency (re-running migration when UserDefaults already cleared is a no-op)

*Framework install: none needed — XCTest is built in to Xcode.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Edge Function rejects unauthenticated requests | SEC-01 | Requires deployed Supabase Edge Function | `curl -X POST https://<supabase-url>/functions/v1/cerebras-proxy -H "Content-Type: application/json" -d '{}'` → expect 401 response |
| CEREBRAS_API_KEY absent from .ipa bundle | SEC-01 | Requires archive build + binary inspection | Build archive → `strings VibeWatchApp.app/VibeWatchApp \| grep -i cerebras` → expect no match |
| Keychain token survives app restart | SEC-02 | Requires device/Simulator restart | Sign in → force-quit app → relaunch → verify still logged in |
| Existing user silently migrated on first update launch | SEC-02 | Requires pre-migration state setup on device | Install pre-migration build (UserDefaults populated) → install post-migration build → verify user still logged in + UserDefaults keys absent |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s (build check)
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
