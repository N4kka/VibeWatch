---
phase: 01-critical-bug-fixes
plan: 02
subsystem: database
tags: [swift, ios, sqlite, supabase, postgresql, xct, migration]

requires:
  - phase: 01-critical-bug-fixes/01-01
    provides: "RED failing tests — testCommentRPCDisabledFlagDoesNotExist, DatabaseMigrationTests"
provides:
  - "Supabase migration 20260305000000_add_clip_comments_updated_at.sql — SET DEFAULT on clip_comments.updated_at"
  - "DatabaseMigrationManager migration 3 — adds updated_at to local SQLite clip_comments with columnExists guard"
  - "commentRPCDisabled flag fully removed from ClipCommentService — clip_add_comment RPC called unconditionally"
affects: [01-03, 01-04, 01-05]

tech-stack:
  added: []
  patterns:
    - "Supabase migration with DO $$ BEGIN ... EXCEPTION WHEN undefined_column END $$ for safe idempotent ALTER COLUMN SET DEFAULT"
    - "DatabaseMigrationManager columnExists guard pattern before ALTER TABLE in iOS migrations"
    - "Pure deletion as bug fix — removing the disable flag rather than working around the schema error"

key-files:
  created:
    - supabase/supabase/migrations/20260305000000_add_clip_comments_updated_at.sql
  modified:
    - VibeWatchApp/Core/Database/DatabaseMigrationManager.swift
    - VibeWatchApp/Core/Services/ClipCommentService.swift

key-decisions:
  - "Used DO $$ BEGIN/EXCEPTION block in SQL migration to handle both missing-DEFAULT and missing-column cases safely — Postgres does not support IF NOT EXISTS for ALTER COLUMN SET DEFAULT"
  - "SQL file committed with git add -f — entire supabase/ is gitignored but one prior migration is tracked; plan artifact list included this file explicitly"
  - "DatabaseMigrationManager latestVersion is 4 (not 3) because linter applied a concurrent plan's BUG-04 migration 4 simultaneously; migration 3 (our fix) is correctly present in the ordered array"
  - "commentRPCDisabled removed by pure deletion — no replacement mechanism; schema fix makes the client-side disable unnecessary"

patterns-established:
  - "Use -derivedDataPath with a temp dir + -clonedSourcePackagesDirPath to run xcodebuild tests concurrently without build DB lock conflicts"

requirements-completed: [BUG-01]

duration: 36min
completed: 2026-03-05
---

# Phase 1 Plan 02: BUG-01 Fix Summary

**PGRST205 clip_add_comment failure fixed: Supabase migration adds DEFAULT to updated_at, SQLite migration 3 adds the column locally, and the commentRPCDisabled disable mechanism is fully deleted from ClipCommentService**

## Performance

- **Duration:** 36 min
- **Started:** 2026-03-05T17:12:32Z
- **Completed:** 2026-03-05T17:49:29Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Created `supabase/supabase/migrations/20260305000000_add_clip_comments_updated_at.sql` with a safe DO/EXCEPTION block that sets DEFAULT on the existing column or adds it if missing, plus NULL backfill
- Added `migration3_AddClipCommentsUpdatedAt()` to `DatabaseMigrationManager` with `columnExists` guard — DatabaseMigrationTests GREEN (2/2)
- Deleted `commentRPCDisabled` property, early-exit guard, and catch-block body from `ClipCommentService` — ClipCommentServiceTests/testCommentRPCDisabledFlagDoesNotExist GREEN

## Task Commits

Each task was committed atomically:

1. **Task 1: Supabase migration + DatabaseMigrationManager version 3** - `743d3af` (feat)
2. **Task 2: Remove commentRPCDisabled from ClipCommentService** - `c59c990` (fix)

**Plan metadata:** (committed with SUMMARY.md, STATE.md, ROADMAP.md)

## Files Created/Modified

- `supabase/supabase/migrations/20260305000000_add_clip_comments_updated_at.sql` - Properly-named Supabase migration; DO block safely sets DEFAULT or adds column; backfills NULLs
- `VibeWatchApp/Core/Database/DatabaseMigrationManager.swift` - Migration 3 added to array and implemented; latestVersion reflects all migrations
- `VibeWatchApp/Core/Services/ClipCommentService.swift` - commentRPCDisabled property, early-exit guard, and catch disable body all deleted

## Decisions Made

- Used a `DO $$ BEGIN ... EXCEPTION WHEN undefined_column` block in the SQL migration because Postgres has no `IF NOT EXISTS` for `ALTER COLUMN SET DEFAULT`. The exception handler runs `ADD COLUMN` as fallback — handles both the deployed-schema-missing-default case and a hypothetical fresh schema case.
- Committed the SQL file with `git add -f` — the `.gitignore` marks `supabase/` as local-only, but the plan's `files_modified` explicitly listed this artifact and one prior migration was already force-tracked.
- `latestVersion` ended up at 4 (not 3) because a concurrent plan added migration 4 via the linter. Migration 3 (our fix) is correctly present in the array; the DatabaseMigrationTests pass regardless of the final version number since they test behavior indirectly.

## Deviations from Plan

### Auto-noted Infrastructure Issues

**1. Concurrent build DB lock — used temp derivedDataPath**
- **Found during:** Task 1 verification
- **Issue:** Multiple parallel `xcodebuild` processes (from other plans executing simultaneously) locked the shared DerivedData build.db, causing every test run to fail with "database is locked"
- **Fix:** Used `-derivedDataPath $(mktemp -d) -clonedSourcePackagesDirPath` to give each test run its own isolated build database while sharing the already-resolved SourcePackages
- **Impact on plan:** Tests passed once isolated; no code changes required

---

**Total deviations:** 0 code deviations — plan executed exactly as written.
**Infrastructure note:** Build DB contention from parallel execution required the temp derivedDataPath workaround, not a code issue.

## Issues Encountered

- Concurrent xcodebuild processes from parallel plan execution locked the shared DerivedData build DB repeatedly. Resolved by using isolated `-derivedDataPath` per test run.
- `swift-protobuf` submodule corruption from concurrent builds. Resolved by force-deiniting the submodule and re-running package resolution.
- `supabase/` gitignore rule blocked `git add` — resolved with `-f` flag, consistent with existing force-tracked migration.

## User Setup Required

**Supabase migration must be applied manually.** The SQL file is committed locally but Supabase Cloud does not auto-apply local migration files.

To apply:
```bash
cd supabase && supabase db push
```
Or apply manually via Supabase Dashboard SQL editor:
```sql
DO $$
BEGIN
  ALTER TABLE public.clip_comments
    ALTER COLUMN updated_at SET DEFAULT timezone('utc', now());
EXCEPTION
  WHEN undefined_column THEN
    ALTER TABLE public.clip_comments
      ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now());
END $$;

UPDATE public.clip_comments SET updated_at = now() WHERE updated_at IS NULL;
```

Until this migration is applied to Supabase Cloud, the `clip_add_comment` RPC may still fail for existing deployments with the missing DEFAULT.

## Next Phase Readiness

- BUG-01 fix complete: schema migration + local SQLite migration + service flag removed
- ClipCommentServiceTests GREEN, DatabaseMigrationTests GREEN
- 01-03 (SyncEngine recovery) can proceed — depends on SyncEngine APIs being stable
- 01-04 (SmartNotificationService.handleNotificationTap) has no dependency on this plan — already committed in prior session

---
*Phase: 01-critical-bug-fixes*
*Completed: 2026-03-05*
