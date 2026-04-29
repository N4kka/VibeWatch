# Discovery ViewModel Repository Migration

## Overview

Continue Phase 4 by migrating `DiscoveryViewModel` to the repository-backed data path. The immediate goal was to make Discovery consume `DiscoveryRepository` snapshots instead of directly generating/loading carousels through `DiscoveryPersonalizationService`, while preserving existing filtering, interaction logging, and UI behavior.

## Technical Approach

- Convert `DiscoveryViewModel` from `ObservableObject` to `@Observable`.
- Inject `DiscoveryRepository` and an explicit `userId` into the view model.
- Update `DiscoveryView` to read `discoveryRepository` from SwiftUI environment and create a repository-backed content view.
- Map `DiscoveryCarouselSnapshot` into existing `PersonalizedCarousel` models so the UI remains unchanged.
- Keep global filters, pro-only filtering, interaction logging, and filter persistence behavior scoped as-is for this batch.
- Add focused tests with `MockDiscoveryRepository` for repository snapshot loading.

## Status

Completed.

Implemented:
- `DiscoveryViewModel` is now `@Observable` and receives `DiscoveryRepository` plus explicit `userId` through its initializer.
- `DiscoveryView` reads `discoveryRepository` from SwiftUI environment and creates a repository-backed content view scoped to the current user.
- Repository `DiscoveryCarouselSnapshot` values are mapped into the existing `PersonalizedCarousel` UI model so carousel rendering remains unchanged.
- Existing global filters, local filter persistence, pro-only hide watched/disliked behavior, gamification, analytics, and interaction logging remain unchanged for this batch.
- `DependencyContainer.makeDiscoveryViewModel()` now injects the live `DiscoveryRepository`.
- `DiscoveryViewModelRepositoryTests` covers loading repository snapshots through `MockDiscoveryRepository`.

Verification:
- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' -only-testing:VibeWatchAppTests/DiscoveryViewModelRepositoryTests`
  - Result: 1 test, 0 failures.
- `xcodebuild test -scheme VibeWatchApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`
  - Result: 126 tests, 0 failures.

## Pros & Cons

Pros:
- Moves Discovery's primary read path onto the repository layer.
- Keeps the UI and carousel rendering model stable.
- Reduces direct singleton data loading in the priority Discovery view model.

Cons:
- Some legacy singleton/service access remains temporarily for filters, list-based hide watched/disliked, analytics, and gamification.
- `DiscoveryPersonalizationService` cleanup remains a follow-up Phase 5 concern.
