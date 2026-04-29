# Detail ViewModels Repository Migration

## Overview

Continue Phase 4 of the data-layer refactor by migrating the movie and TV detail view models away from direct singleton data loading and toward injected repository dependencies. The goal is to make detail screens render cached SQLite data immediately through `MediaRepository`, then refresh in the background, while keeping the existing UI behavior stable.

## Technical Approach

- Convert `MovieDetailViewModel` and `TVShowDetailViewModel` from `ObservableObject` to `@Observable`.
- Inject `MediaRepository` through view model initializers, keeping other legacy services as explicit dependencies only where still needed.
- Update `MovieDetailView` and `TVShowDetailView` to read `mediaRepository` from SwiftUI environment and store the view model with `@State`.
- Route detail and availability loading through `MediaRepository.details` and `MediaRepository.availability`.
- Keep list membership mutations on `ListRepository` where practical, without bundling reaction-service refactors into this batch.
- Add focused tests with `MockMediaRepository` for movie and TV detail snapshots from repository data.

## Status

Approved by user as the next phase after validating the duplicate-list production data cleanup.

Implementation complete:

- `MovieDetailViewModel` and `TVShowDetailViewModel` are now `@Observable`.
- Both view models accept an injected `MediaRepository` and load the first detail snapshot from it.
- `MovieDetailView` and `TVShowDetailView` read `mediaRepository` from SwiftUI environment and initialize repository-backed content views with `@State` view models.
- `DependencyContainer` passes its live `mediaRepository` into detail view model factories.
- Added `DetailViewModelRepositoryTests` for movie and TV repository snapshots.

Verification complete:

- `xcodebuild -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build -quiet` passed with existing warnings only.
- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/DetailViewModelRepositoryTests -only-testing:VibeWatchAppTests/LiveMediaRepositoryTests` passed: 4 tests.
- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'` passed: 125 tests.

## Pros & Cons

Pros:
- Detail screens gain the same cache-first SWR behavior as lists.
- Reduces direct `.shared` usage in priority view models.
- Keeps the batch scoped to detail data flow instead of mixing in Discovery carousel cleanup.

Cons:
- Some legacy service dependencies may remain temporarily for AI summary, reactions, quota, or preferences.
- `MovieDetailView.swift` and `TVShowDetailView.swift` are large files, so this batch needs careful build verification.
