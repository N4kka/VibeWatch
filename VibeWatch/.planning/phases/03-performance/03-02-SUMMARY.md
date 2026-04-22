---
phase: 03-performance
plan: "02"
subsystem: database
tags: [sqlite, concurrency, wal, dispatch-queue, ios]

requires:
  - phase: 03-00
    provides: WAL mode already enabled in SQLiteService; dbQueue serial queue baseline

provides:
  - SQLiteService.readerQueue (concurrent DispatchQueue, label com.vibewatch.sqlite.reader)
  - SQLiteService.readerDb (read-only OpaquePointer, SQLITE_OPEN_READONLY | FULLMUTEX)
  - SQLiteService.writerQueue (serial DispatchQueue renamed from dbQueue)
  - queryRaw() now dispatches to readerQueue + readerDb (non-blocking vs writes)

affects:
  - 03-03-performance (uses SQLiteService queryRaw for cache reads)
  - Any future plan that reads SQLiteService internals

tech-stack:
  added: []
  patterns:
    - "Writer/reader queue split: serial writerQueue for mutations, concurrent readerQueue for SELECTs"
    - "SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX for shared read-only connection with concurrent queue"
    - "openReaderConnection() must be called AFTER WAL PRAGMA is set"

key-files:
  created: []
  modified:
    - VibeWatchApp/Core/Database/SQLiteService.swift
    - VibeWatchAppTests/PerformanceTests.swift

key-decisions:
  - "SQLITE_OPEN_FULLMUTEX (not NOMUTEX) required for shared readerDb on concurrent queue — NOMUTEX caused illegal multi-threaded access crash"
  - "readerQueue declared as let (not private let) so @testable import can access readerQueue.label in tests"
  - "closeDatabase() and deinit both close readerDb before writerDb to prevent dangling pointer"

patterns-established:
  - "Always open read-only connection after WAL PRAGMA to ensure WAL is active before reader attaches"
  - "resetDatabase() must nil out readerDb before reopening so openReaderConnection() gets a fresh pointer"

requirements-completed:
  - PERF-03

duration: 10min
completed: 2026-04-22
---

# Phase 03 Plan 02: Concurrent Reader Queue Summary

**SQLiteService split into serial writerQueue + concurrent readerQueue, with a dedicated read-only SQLite connection (SQLITE_OPEN_READONLY | FULLMUTEX) opened after WAL PRAGMA, eliminating read-write serialization bottleneck**

## Performance

- **Duration:** 10 min
- **Started:** 2026-04-22T06:24:08Z
- **Completed:** 2026-04-22T06:34:31Z
- **Tasks:** 1 (TDD: RED + GREEN)
- **Files modified:** 2

## Accomplishments

- Renamed `dbQueue` to `writerQueue` (serial, label: `com.vibewatch.sqlite.writer`) throughout SQLiteService
- Added `readerQueue` (concurrent DispatchQueue, label: `com.vibewatch.sqlite.reader`) as an accessible `let` for test verification
- Added `readerDb` (read-only SQLite connection) opened with `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` after WAL PRAGMA
- `queryRaw()` now dispatches to `readerQueue` using `readerDb` — concurrent reads no longer block writes
- Both `db` and `readerDb` properly closed in `closeDatabase()` and `deinit`
- `testConcurrentReadDoesNotBlockWrite` PASSES; PERF-01/02 tests continue to pass

## Task Commits

Each task was committed atomically:

1. **RED: testConcurrentReadDoesNotBlockWrite** - `4b585aa` (test)
2. **GREEN: Split SQLiteService writer + concurrent reader queue** - `09a3e49` (feat)

_Note: TDD task has two commits (test RED → feat GREEN)_

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `VibeWatchApp/Core/Database/SQLiteService.swift` — Added writerQueue, readerQueue, readerDb, openReaderConnection(); updated execute/queryRaw/insert/performBatchInsert/closeDatabase/deinit/resetDatabase
- `VibeWatchAppTests/PerformanceTests.swift` — Replaced XCTFail RED stub with real concurrent read test verifying readerQueue.label and 10-concurrent-dispatch non-deadlock

## Decisions Made

- **SQLITE_OPEN_FULLMUTEX over NOMUTEX**: The plan specified NOMUTEX, but using a concurrent DispatchQueue with a shared connection and NOMUTEX caused `libsqlite3.dylib: illegal multi-threaded access to database connection` crash. FULLMUTEX lets SQLite's internal mutex serialize access to the shared `readerDb` handle while still allowing concurrent dispatch at the queue level.
- **readerQueue as `let` (not `private let`)**: Required so `@testable import VibeWatchApp` can access `readerQueue.label` for assertion in tests.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Changed SQLITE_OPEN_NOMUTEX to SQLITE_OPEN_FULLMUTEX for reader connection**
- **Found during:** Task 1 GREEN phase
- **Issue:** Plan specified `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_SHAREDCACHE`. With a concurrent DispatchQueue, multiple blocks can call `sqlite3_prepare_v2` on `readerDb` simultaneously. NOMUTEX removes SQLite's built-in thread protection, causing a crash: "BUG IN CLIENT OF libsqlite3.dylib: illegal multi-threaded access to database connection"
- **Fix:** Replaced `NOMUTEX | SHAREDCACHE` with `FULLMUTEX`. This serializes access to the shared reader handle at the SQLite layer while allowing concurrent dispatch at the DispatchQueue layer.
- **Files modified:** VibeWatchApp/Core/Database/SQLiteService.swift
- **Verification:** testConcurrentReadDoesNotBlockWrite PASSES without crash
- **Committed in:** 09a3e49 (GREEN task commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - bug)
**Impact on plan:** Essential correctness fix. The NOMUTEX flag is incompatible with a shared connection on a concurrent queue. FULLMUTEX achieves the same WAL-mode concurrency goal safely.

## Issues Encountered

- First test run crashed with "Early unexpected exit... test runner crashed before establishing connection" - resolved by explicitly booting the simulator before the test run.

## Next Phase Readiness

- `readerQueue` and `readerDb` are live; 03-03 can use `queryRaw()` for all cache-first reads with concurrent dispatch
- No regressions in existing PerformanceTests (PERF-01, PERF-02 pass; PERF-04 RED stubs remain failing as expected)

---
*Phase: 03-performance*
*Completed: 2026-04-22*
