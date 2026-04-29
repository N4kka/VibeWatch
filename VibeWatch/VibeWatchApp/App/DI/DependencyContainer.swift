import Foundation
import SwiftUI

/// Dependency injection container for the application.
/// Manages service lifecycles and provides factory methods for ViewModels.
/// Replaces singleton pattern with centralized dependency management.
@MainActor
final class DependencyContainer: ObservableObject {

    // MARK: - Singleton

    static let shared = DependencyContainer()

    // MARK: - Core Services (Lazy Singletons)

    lazy var authService = AuthService.shared
    lazy var listManager = ListManager.shared
    lazy var gamificationService = GamificationService.shared
    lazy var syncEngine = SyncEngine.shared

    // MARK: - Repository & Data Services

    lazy var clipsRepository = ClipsRepository.shared
    lazy var listRepository: any ListRepository = LiveListRepository()
    lazy var mediaRepository: any MediaRepository = LiveMediaRepository()
    lazy var discoveryRepository: any DiscoveryRepository = LiveDiscoveryRepository()
    lazy var notificationRepository: any NotificationRepository = LiveNotificationRepository()
    lazy var imageCache = ImageCacheService.shared

    // MARK: - Feature Services

    lazy var movieReactionService = MovieReactionService.shared
    lazy var clipCommentService = ClipCommentService.shared

    // MARK: - Supporting Services

    lazy var tmdbService = TMDBService.shared
    lazy var clipsService = ClipsService.shared
    lazy var detailCache = DetailCacheService.shared
    lazy var prefetchService = ClipsPrefetchService.shared
    lazy var userPreferenceManager = UserPreferenceManager.shared
    lazy var personalizationService = DiscoveryPersonalizationService.shared
    lazy var sqliteService = SQLiteService.shared
    lazy var dailyQuotaManager = DailyQuotaManager.shared
    lazy var streamingService = StreamingAvailabilityService.shared
    lazy var clipQuotaService = ClipQuotaService.shared
    lazy var cerebrasService = CerebrasService.shared
    lazy var aiTokenManager = AITokenManager.shared
    lazy var languageDetector = LanguageDetector.shared
    lazy var queryClassifier = AIQueryClassifier.shared
    lazy var contextBuilder = AIContextBuilder.shared
    lazy var conversationMemory = ConversationMemoryManager.shared

    // MARK: - Initialization

    private init() {
        // Private init to enforce singleton
    }

    // MARK: - ViewModel Factory Methods

    /// Creates a ClipsViewModel with injected dependencies
    func makeClipsViewModel() -> ClipsViewModel {
        ClipsViewModel(repository: ClipsRepository.shared)
    }

    /// Creates a ClipsSearchViewModel with injected dependencies
    func makeClipsSearchViewModel() -> ClipsSearchViewModel {
        ClipsSearchViewModel(
            searchService: ClipsSearchService.shared,
            clipsService: clipsService
        )
    }

    /// Creates a DiscoveryViewModel with injected dependencies
    func makeDiscoveryViewModel() -> DiscoveryViewModel {
        DiscoveryViewModel(
            repository: discoveryRepository,
            quotaManager: dailyQuotaManager,
            preferenceManager: userPreferenceManager,
            sqliteService: sqliteService
        )
    }

    /// Creates a MovieDetailViewModel with injected dependencies
    func makeMovieDetailViewModel(movieId: Int) -> MovieDetailViewModel {
        MovieDetailViewModel(
            movieId: movieId,
            mediaRepository: mediaRepository,
            tmdbService: tmdbService,
            streamingService: streamingService,
            detailCache: detailCache,
            quotaService: clipQuotaService,
            cerebrasService: cerebrasService,
            preferenceManager: userPreferenceManager,
            aiTokenManager: aiTokenManager
        )
    }

    /// Creates a TVShowDetailViewModel with injected dependencies
    func makeTVShowDetailViewModel(tvShowId: Int) -> TVShowDetailViewModel {
        TVShowDetailViewModel(
            tvShowId: tvShowId,
            mediaRepository: mediaRepository,
            tmdbService: tmdbService,
            streamingService: streamingService,
            detailCache: detailCache,
            quotaService: clipQuotaService,
            cerebrasService: cerebrasService,
            preferenceManager: userPreferenceManager,
            aiTokenManager: aiTokenManager
        )
    }

    // Note: TV show detail view uses the same ViewModel - add factory when needed
    // func makeMovieDetailViewModelForTVShow(tvShowId: Int) -> MovieDetailViewModel {
    //     MovieDetailViewModel(tvShowId: tvShowId)
    // }

    /// Creates a SearchViewModel with injected dependencies
    func makeSearchViewModel() -> SearchViewModel {
        SearchViewModel(
            tmdbService: tmdbService,
            preferenceManager: userPreferenceManager
        )
    }

    /// Creates an ActorDetailViewModel with injected dependencies
    func makeActorDetailViewModel(personId: Int) -> ActorDetailViewModel {
        ActorDetailViewModel(personId: personId, tmdbService: tmdbService)
    }

    /// Creates an AIRecommendationViewModel with injected dependencies
    func makeAIRecommendationViewModel() -> AIRecommendationViewModel {
        AIRecommendationViewModel(
            authService: authService,
            aiTokenManager: aiTokenManager,
            languageDetector: languageDetector,
            tmdbService: tmdbService,
            cerebrasService: cerebrasService,
            preferenceManager: userPreferenceManager,
            queryClassifier: queryClassifier,
            contextBuilder: contextBuilder,
            conversationMemory: conversationMemory
        )
    }

    /// Creates a ListsViewModel with injected dependencies
    func makeListsViewModel() -> ListsViewModel {
        ListsViewModel(
            repository: listRepository,
            userId: authService.currentUser?.id ?? "anonymous"
        )
    }

    /// Creates an OnboardingViewModel with injected dependencies
    func makeOnboardingViewModel() -> OnboardingViewModel {
        OnboardingViewModel()
    }
}

// MARK: - Environment Key

private struct DependencyContainerKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: DependencyContainer {
        MainActor.assumeIsolated { DependencyContainer.shared }
    }
}

extension EnvironmentValues {
    var dependencies: DependencyContainer {
        get { self[DependencyContainerKey.self] }
        set { self[DependencyContainerKey.self] = newValue }
    }
}
