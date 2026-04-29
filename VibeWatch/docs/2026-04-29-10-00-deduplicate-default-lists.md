# Deduplicate Default Lists

## Overview

Authenticated users can have multiple default lists with the same `user_id` and `type` in Supabase, especially from earlier development builds. The app currently treats the first matching default list as the active one, so a newer empty `watchlist` can hide an older `watchlist` containing 100+ items.

## Technical Approach

- Normalize default list duplicates in the repository read path for `watchlist`, `seen`, `liked`, and `disliked`.
- Pick the canonical default list by item count, using the list with the most items as the destination.
- Merge duplicate default list items by `media_id + media_type`, preserving the newest item metadata when duplicates exist.
- Keep custom lists independent.
- Prepare Supabase SQL with a read-only dry-run section and a separate transactional execute section so production data can be inspected before any mutation.

## Status

Approved strategy: canonical list = list with the most items.

Implementation complete in the app repository layer:

- Remote and local default-list snapshots are normalized before the UI receives them.
- Duplicate default lists are merged in memory by type, choosing the list with the most items as canonical.
- `markAsSeen` now uses the same normalized default-list selection path.
- Added a Supabase SQL runbook at `docs/2026-04-29-10-00-deduplicate-default-lists.sql` with dry-run, execute, and post-check sections.

Verification complete:

- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/LiveListRepositoryTests -only-testing:VibeWatchAppTests/ListsViewModelTests` passed: 6 tests.
- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'` passed: 123 tests.

## Pros & Cons

Pros:
- Preserves the richest historical default list automatically.
- Prevents empty duplicate default lists from hiding existing saved items.
- App-side normalization protects users even before the Supabase cleanup runs.

Cons:
- A server-side cleanup is still needed to remove or soft-delete existing duplicate rows.
- If two duplicate lists have different intended meanings despite sharing the same default type, the merge treats them as one default list.
