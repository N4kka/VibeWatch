---
phase: 2
slug: security-hardening
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-06
audited: 2026-05-07
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
| 2-01-01 | 01 | 0 | SEC-01, SEC-02 | unit stubs | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/KeychainStorageTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ✅ | ✅ green |
| 2-01-02 | 01 | 0 | SEC-02 | unit stubs | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/AuthMigrationTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ✅ | ✅ green |
| 2-01-03 | 01 | 1 | SEC-01 | build-time | `xcodebuild build -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| grep -E 'error:|BUILD'` | N/A | ✅ green |
| 2-01-04 | 01 | 1 | SEC-01 | build-time | same as above | N/A | ✅ green |
| 2-02-01 | 02 | 2 | SEC-02 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/KeychainStorageTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ✅ | ✅ green |
| 2-02-02 | 02 | 2 | SEC-02 | unit | `xcodebuild test -scheme VibeWatchApp -only-testing VibeWatchAppTests/AuthMigrationTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 \| tail -20` | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `VibeWatchAppTests/KeychainStorageTests.swift` — unit tests for `KeychainStorage.store/retrieve/remove` (covers SEC-02 Keychain read/write/delete on live Simulator Keychain)
- [x] `VibeWatchAppTests/AuthMigrationTests.swift` — unit tests for migration success path, failure path (forced re-login), and idempotency (re-running migration when UserDefaults already cleared is a no-op)

*Framework install: none needed — XCTest is built in to Xcode.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Edge Function rejects unauthenticated requests | SEC-01 | Requires deployed Supabase Edge Function | `curl -X POST https://<supabase-url>/functions/v1/cerebras-proxy -H "Content-Type: application/json" -d '{}'` → expect 401 response | ✅ verified 2026-05-07 — returned `{"error":"Missing Authorization header"}` |
| CEREBRAS_API_KEY absent from .ipa bundle | SEC-01 | Requires archive build + binary inspection | Build archive → `strings VibeWatchApp.app/VibeWatchApp \| grep -i cerebras` → expect no match |
| Keychain token survives app restart | SEC-02 | Requires device/Simulator restart | Sign in → force-quit app → relaunch → verify still logged in | ✅ verified 2026-05-07 |
| Existing user silently migrated on first update launch | SEC-02 | Requires pre-migration state setup on device | Install pre-migration build (UserDefaults populated) → install post-migration build → verify user still logged in + UserDefaults keys absent |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s (build check)
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** 2026-05-07

---

## Validation Audit 2026-05-07

| Metric | Count |
|--------|-------|
| Gaps found | 0 |
| Resolved | 0 |
| Escalated | 0 |
| Manual-only | 4 |

Both test files (KeychainStorageTests 6 tests, AuthMigrationTests 3 tests) confirmed on disk and GREEN per VERIFICATION.md. Build-time SEC-01 checks verified via code inspection (cerebrasAPIKey absent, proxy wired). 4 manual items (Edge Function live 401, binary inspection, Keychain runtime, migration on-device) remain manual.
