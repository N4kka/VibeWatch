# Milestones

## v1.0 Production Stabilization (Shipped: 2026-05-07)

**Phases completed:** 4 phases, 14 plans | **Timeline:** 2025-11-14 → 2026-05-07 | **Swift LOC:** ~55,600

**Key accomplishments:**
1. Comments sync restored — Supabase + SQLite migration, `commentRPCDisabled` fully deleted
2. SyncEngine PGRST205 recovery — `unblockAndRetryBlockedOperations()` wired at launch before push
3. Push notification deep-link — full routing to Movie/TVShowDetailView; cold-launch path via `.onAppear`
4. Cerebras API key secured — Edge Function proxy with JWT auth; key deleted from app bundle
5. Auth tokens encrypted at rest — KeychainStorage with silent UserDefaults migration on first launch
6. Instant cache launch — concurrent SQLite reader queue, carousel dedup, splash SQLite early-exit, 186 prints → Logger, MultiDeviceSyncTests green

**Tech debt carried forward:** ClipsView/ListsView refactor, ConflictResolverTests failures, Nyquist VALIDATION.md drafts → v2

**Archive:** `.planning/milestones/v1.0-ROADMAP.md`, `.planning/milestones/v1.0-REQUIREMENTS.md`, `.planning/milestones/v1.0-MILESTONE-AUDIT.md`

---

