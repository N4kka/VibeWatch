# Requirements: VibeWatch v1.0 Production

**Defined:** 2026-03-05
**Core Value:** Content and user data load under 500ms — instant from first tap, never silently loses data

## v1 Requirements

### Critical Bugs

- [x] **BUG-01**: Comments sync to Supabase — fix missing `updated_at` column in backend schema so `clip_add_comment` RPC succeeds and `commentRPCDisabled` flag is never set
- [x] **BUG-02**: SyncEngine recovers from PGRST205-blocked operations — add a recovery path so permanently stuck operations can be unblocked when backend schema is later corrected
- [x] **BUG-03**: Push notification taps navigate to relevant content — implement `SmartNotificationService.handleNotificationTap` to route to movie/show via `AppNavigationManager`
- [x] **BUG-04**: Analytics Dashboard shows mood analysis — implement or remove `moodAnalysis` field in `AnalyticsInsightsService.generateUserStatistics`

### Security

- [ ] **SEC-01**: Cerebras API key never leaves the server — proxy all `CerebrasService` calls through a Supabase Edge Function; remove key from app bundle
- [x] **SEC-02**: Auth session tokens stored in Keychain — migrate `AuthService` token persistence from `UserDefaults` to iOS Keychain

### Performance

- [ ] **PERF-01**: App launch reaches usable Discovery screen in under 500ms from cache — verify and enforce the instant-launch path in `AppState.loadCachedContentSync()`
- [ ] **PERF-02**: Personalization carousels generated once per cold start — deduplicate the two `generatePersonalizedCarousels` call sites in `AppState` so carousel generation runs at most once per launch
- [ ] **PERF-03**: SQLite supports concurrent reads — add a dedicated reader queue alongside the existing writer queue, using WAL mode (already enabled) to allow parallel reads without blocking writes
- [ ] **PERF-04**: Discovery, Movie/TV detail, and Clips screens show cached content instantly — audit each screen's data load path and ensure cache-first reads with background refresh

### Code Quality

- [ ] **QUAL-01**: All 212 `print()` calls replaced with `Logger` — no raw print statements in production code paths
- [ ] **QUAL-02**: `MultiDeviceSyncTests.swift` updated to use `SyncEngine` and `ConflictResolver` APIs — test compiles and passes, covering core sync conflict resolution

## v2 Requirements

### Architecture

- **ARCH-01**: `DependencyContainer` fully decouples services from `.shared` — views consume services via `@EnvironmentObject` only
- **ARCH-02**: `ClipsView.swift` (1764 lines) extracted into focused subview files
- **ARCH-03**: `ListsView.swift` (1602 lines) extracted into focused subview files
- **ARCH-04**: Centralize device ID generation in `InstallIDService`

### Testing

- **TEST-01**: Quota management and paywall logic covered by unit tests
- **TEST-02**: SQLite migration paths covered by unit tests
- **TEST-03**: UI/integration tests for core user flows (sign-up, list creation, clip playback)

### Observability

- **OBS-01**: Third-party error tracking integrated (Sentry or Crashlytics)
- **OBS-02**: YouTube API quota exhaustion handled gracefully with server-side pre-validation

## Out of Scope

| Feature | Reason |
|---------|--------|
| New UI features | This milestone is stabilization only |
| UI file refactors (ClipsView/ListsView split) | Not user-visible, deferred to v2 |
| Full DI refactor | Architecture debt, not blocking production |
| Mood analysis full implementation | Remove nil stub — defer full feature to v2 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUG-01 | Phase 1 | Complete |
| BUG-02 | Phase 1 | Complete |
| BUG-03 | Phase 1 | Complete |
| BUG-04 | Phase 1 | Complete |
| SEC-01 | Phase 2 | Pending |
| SEC-02 | Phase 2 | Complete |
| PERF-01 | Phase 3 | Pending |
| PERF-02 | Phase 3 | Pending |
| PERF-03 | Phase 3 | Pending |
| PERF-04 | Phase 3 | Pending |
| QUAL-01 | Phase 4 | Pending |
| QUAL-02 | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 12 total
- Mapped to phases: 12
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-05*
*Last updated: 2026-03-05 after initial definition*
