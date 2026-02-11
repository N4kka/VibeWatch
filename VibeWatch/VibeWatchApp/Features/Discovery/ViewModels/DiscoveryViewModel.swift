import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
class DiscoveryViewModel: ObservableObject {
    @Published var personalizedCarousels: [PersonalizedCarousel] = []
    @Published var globalFilters: GlobalDiscoveryFilters
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var error: AppError?
    @Published var refreshToken = UUID()
    
    var hasNoContent: Bool {
        personalizedCarousels.isEmpty
    }
    
    private let preferenceManager: UserPreferenceManager
    private let personalizationService: DiscoveryPersonalizationService
    private let sqliteService: SQLiteService
    private let quotaManager: DailyQuotaManager
    private var cancellables = Set<AnyCancellable>()
    private var generatedCarousels: [PersonalizedCarousel] = []
    private let userDefaults = UserDefaults.standard
    private var hasLoadedOnce = false
    private var loadTask: Task<Void, Never>?

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(
        quotaManager: DailyQuotaManager = .shared,
        preferenceManager: UserPreferenceManager = .shared,
        personalizationService: DiscoveryPersonalizationService = .shared,
        sqliteService: SQLiteService = .shared
    ) {
        self.quotaManager = quotaManager
        self.preferenceManager = preferenceManager
        self.personalizationService = personalizationService
        self.sqliteService = sqliteService
        self.globalFilters = GlobalDiscoveryFilters.load()

        Task {
            await loadGlobalFiltersFromDatabaseIfAvailable()
        }

        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadTask?.cancel()
                self.loadTask = Task { [weak self] in
                    guard let self else { return }
                    await self.loadContentIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        loadTask?.cancel()
    }

    // Alias for loadContent to fix call site compatibility
    func loadDiscoveryContent() async {
        await loadContent()
    }

    func loadContentIfNeeded() async {
        if shouldReloadForNewDay() {
            await loadContent(forceRefresh: true)
        } else {
            await loadContent(forceRefresh: false)
        }
    }

    /// Load content - uses database cache for instant loading!
    func loadContent(forceRefresh: Bool = false) async {
        Logger.debug("[DiscoveryViewModel] Loading personalized Discovery... forceRefresh: \(forceRefresh)")

        // Avoid reloading (and resetting scroll) when coming back from a detail screen.
        if !forceRefresh, hasLoadedOnce, !hasNoContent, !shouldReloadForNewDay() {
            return
        }

        if !forceRefresh, !personalizationService.hasCachedData {
            let userId = AuthService.shared.currentUser?.id
            if let cached = await personalizationService.loadCachedCarouselsIfAvailable(userId: userId) {
                generatedCarousels = cached
                personalizedCarousels = applyGlobalFilters(to: cached)
                hasLoadedOnce = true
            }
        }

        if !forceRefresh, hasLoadedOnce, !hasNoContent, !shouldReloadForNewDay() {
            return
        }

        if forceRefresh {
            isRefreshing = true
        } else {
            // Only show loader if we don't have cached data ready to go
            if !personalizationService.hasCachedData {
                isLoading = true
            }
        }
        error = nil
        
        do {
            let profile = await preferenceManager.aggregatePreferences()
            let carousels = try await personalizationService.generatePersonalizedCarousels(
                userProfile: profile,
                filters: globalFilters,
                forceRefresh: forceRefresh
            )
            generatedCarousels = carousels
            self.personalizedCarousels = applyGlobalFilters(to: generatedCarousels)

            Logger.debug("[DiscoveryViewModel] Loaded \(personalizedCarousels.count) personalized carousels")
            hasLoadedOnce = true
            markReloadedForToday()
            
        } catch {
            Logger.error("[DiscoveryViewModel] Failed to load personalized content: \(error)")
            self.error = AppError.network(error)
        }
        
        isLoading = false
        isRefreshing = false
        if forceRefresh {
            refreshToken = UUID()
        }
    }

    func applyFilters(_ filters: GlobalDiscoveryFilters) {
        var sanitized = filters
        if !quotaManager.isProUser {
            sanitized.hideWatched = false
            sanitized.hideDisliked = false
        }

        globalFilters = sanitized
        globalFilters.save()

        personalizedCarousels = applyGlobalFilters(to: generatedCarousels)
        refreshToken = UUID()

        Task {
            await persistGlobalFilters()
        }
    }

    func recordCarouselClick(movie: Movie, carouselType: CarouselType, mediaType: MediaType) {
        preferenceManager.recordInteraction(
            UserInteraction(
                source: .discovery,
                mediaId: movie.id,
                mediaType: mediaType,
                genreIds: movie.genreIds,
                engagementScore: 1.0,
                metadata: [
                    "carousel_type": carouselType.rawValue,
                    "interaction_type": "click"
                ]
            )
        )

        Task {
            await insertDiscoveryInteraction(
                movie: movie,
                carouselType: carouselType,
                mediaType: mediaType,
                interactionType: "click"
            )
        }
    }
    
    /// Refresh content - called by pull-to-refresh gesture
    func refreshContent() async {
        await loadContent(forceRefresh: true)
    }

    private func shouldReloadForNewDay() -> Bool {
        let userId = AuthService.shared.currentUser?.id.lowercased() ?? "anon"
        let key = "discovery_last_loaded_day_\(userId)"
        let todayKey = Self.dayKeyFormatter.string(from: Date())
        let stored = userDefaults.string(forKey: key)
        return stored != todayKey
    }

    private func markReloadedForToday() {
        let userId = AuthService.shared.currentUser?.id.lowercased() ?? "anon"
        let key = "discovery_last_loaded_day_\(userId)"
        let todayKey = Self.dayKeyFormatter.string(from: Date())
        userDefaults.set(todayKey, forKey: key)
    }
    
    // MARK: - Filtering

    private func applyGlobalFilters(to carousels: [PersonalizedCarousel]) -> [PersonalizedCarousel] {
        var filteredCarousels: [PersonalizedCarousel] = []

        for carousel in carousels {
            if globalFilters.mediaType == .movies, carousel.type == .topTVPicks {
                continue
            }
            if globalFilters.mediaType == .tvShows, carousel.type != .topTVPicks {
                continue
            }

            var items = carousel.items
            items = applyItemFilters(items)
            items = sortItems(items, sortBy: globalFilters.sortBy)

            if quotaManager.isProUser {
                if globalFilters.hideWatched {
                    items = filterWatched(movies: items)
                }
                if globalFilters.hideDisliked {
                    items = filterDisliked(movies: items)
                }
            }

            if !items.isEmpty {
                filteredCarousels.append(
                    PersonalizedCarousel(
                        type: carousel.type,
                        title: carousel.title,
                        items: items,
                        descriptions: carousel.descriptions,
                        reason: carousel.reason
                    )
                )
            }
        }

        return filteredCarousels
    }

    private func applyItemFilters(_ items: [Movie]) -> [Movie] {
        let runtimeRange = globalFilters.getRuntimeRange()
        let ratingRange = globalFilters.getRatingRange()
        let yearRange = globalFilters.getYearRange()

        return items.filter { movie in
            if let minRuntime = runtimeRange.min, let runtime = movie.runtime, runtime < minRuntime {
                return false
            }
            if let maxRuntime = runtimeRange.max, let runtime = movie.runtime, runtime > maxRuntime {
                return false
            }

            if let minRating = ratingRange.min, movie.voteAverage < minRating {
                return false
            }
            if let maxRating = ratingRange.max, movie.voteAverage > maxRating {
                return false
            }

            if let startYear = yearRange.start, let year = parseYear(from: movie.releaseDate), year < startYear {
                return false
            }
            if let endYear = yearRange.end, let year = parseYear(from: movie.releaseDate), year > endYear {
                return false
            }

            if !globalFilters.countries.isEmpty,
               let productionCountries = movie.productionCountries {
                let allowed = Set(globalFilters.countries)
                if !productionCountries.contains(where: { allowed.contains($0.iso) }) {
                    return false
                }
            }

            return true
        }
    }

    private func sortItems(_ items: [Movie], sortBy: DiscoverySortOption) -> [Movie] {
        switch sortBy {
        case .popularityDesc:
            return items.sorted { $0.popularity > $1.popularity }
        case .popularityAsc:
            return items.sorted { $0.popularity < $1.popularity }
        case .ratingDesc:
            return items.sorted { $0.voteAverage > $1.voteAverage }
        case .ratingAsc:
            return items.sorted { $0.voteAverage < $1.voteAverage }
        case .releaseDateDesc:
            return items.sorted { parseComparableDate($0.releaseDate) > parseComparableDate($1.releaseDate) }
        case .releaseDateAsc:
            return items.sorted { parseComparableDate($0.releaseDate) < parseComparableDate($1.releaseDate) }
        }
    }

    private func parseYear(from releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    private func parseComparableDate(_ dateString: String?) -> Date {
        guard let dateString else { return .distantPast }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString) ?? .distantPast
    }

    private func filterWatched(movies: [Movie]) -> [Movie] {
        let listManager = ListManager.shared
        let seenItems = Set(listManager.seenList.items.map { $0.mediaId })
        return movies.filter { !seenItems.contains($0.id) }
    }

    private func filterDisliked(movies: [Movie]) -> [Movie] {
        let listManager = ListManager.shared
        let dislikedItems = Set(listManager.dislikedList.items.map { $0.mediaId })
        return movies.filter { !dislikedItems.contains($0.id) }
    }

    // MARK: - Interaction Logging

    private func insertDiscoveryInteraction(
        movie: Movie,
        carouselType: CarouselType,
        mediaType: MediaType,
        interactionType: String
    ) async {
        guard let userId = AuthService.shared.currentUser?.id else {
            return
        }

        let deviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") ?? "unknown"
        let now = ISO8601DateFormatter().string(from: Date())
        let recordId = UUID().uuidString

        let filterConfigData = try? JSONEncoder().encode(globalFilters)
        let filterConfigString = filterConfigData.flatMap { String(data: $0, encoding: .utf8) }
        let filterConfigJSON: Any = {
            guard let filterConfigData else { return NSNull() }
            return (try? JSONSerialization.jsonObject(with: filterConfigData)) ?? NSNull()
        }()

        do {
            let record: [String: Any] = [
                "id": recordId,
                "user_id": userId,
                "device_id": deviceId,
                "media_id": movie.id,
                "media_type": mediaType.rawValue,
                "carousel_type": carouselType.rawValue,
                "interaction_type": interactionType,
                "interacted_at": now,
                "session_duration": NSNull(),
                "filter_active": globalFilters.isActive,
                "filter_config": filterConfigString ?? NSNull(),
                "synced_at": NSNull()
            ]

            _ = try await sqliteService.insert(
                "user_discovery_interactions",
                values: record
            )

            do {
                try await SyncEngine.shared.queueOperation(
                    table: "user_discovery_interactions",
                    operationType: "INSERT",
                    recordId: recordId,
                    payload: record.merging(["filter_config": filterConfigJSON]) { _, new in new },
                    dependsOn: nil
                )
            } catch {
                Logger.error("[DiscoveryViewModel] Failed to queue interaction sync: \(error)")
            }
        } catch {
            Logger.error("[DiscoveryViewModel] Failed to insert discovery interaction", error: error)
        }
    }

    // MARK: - Filter Persistence (SQLite + Sync)

    private func loadGlobalFiltersFromDatabaseIfAvailable() async {
        guard let userId = AuthService.shared.currentUser?.id else {
            return
        }

        do {
            let rows = try await sqliteService.queryRaw(
                "SELECT * FROM global_discovery_filters WHERE user_id = ? LIMIT 1",
                parameters: [userId]
            )
            guard let row = rows.first else {
                return
            }

            var loaded = GlobalDiscoveryFilters()

            if let mediaType = row["media_type"] as? String {
                switch mediaType {
                case "movie": loaded.mediaType = .movies
                case "tv": loaded.mediaType = .tvShows
                default: loaded.mediaType = .both
                }
            }

            if let runtimeMin = row["runtime_min"] as? Int {
                loaded.runtimePreset = .custom
                loaded.customRuntimeMin = runtimeMin
            }
            if let runtimeMax = row["runtime_max"] as? Int {
                loaded.runtimePreset = .custom
                loaded.customRuntimeMax = runtimeMax
            }

            if let ratingMin = row["rating_min"] as? Double {
                loaded.ratingPreset = .custom
                loaded.customRatingMin = ratingMin
            }
            if let ratingMax = row["rating_max"] as? Double {
                loaded.ratingPreset = .custom
                loaded.customRatingMax = ratingMax
            }

            if let yearStart = row["release_year_start"] as? Int {
                loaded.releasePeriodPreset = .custom
                loaded.customYearStart = yearStart
            }
            if let yearEnd = row["release_year_end"] as? Int {
                loaded.releasePeriodPreset = .custom
                loaded.customYearEnd = yearEnd
            }

            if let countriesString = row["countries"] as? String,
               let data = countriesString.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                loaded.countries = arr
            }

            if let sortBy = row["sort_by"] as? String {
                switch sortBy {
                case "rating": loaded.sortBy = .ratingDesc
                case "release_date": loaded.sortBy = .releaseDateDesc
                default: loaded.sortBy = .popularityDesc
                }
            }

            loaded.hideWatched = (row["hide_watched"] as? Bool) ?? ((row["hide_watched"] as? Int).map { $0 == 1 } ?? false)
            loaded.hideDisliked = (row["hide_disliked"] as? Bool) ?? ((row["hide_disliked"] as? Int).map { $0 == 1 } ?? false)

            if !quotaManager.isProUser {
                loaded.hideWatched = false
                loaded.hideDisliked = false
            }

            globalFilters = loaded
            globalFilters.save()
            personalizedCarousels = applyGlobalFilters(to: generatedCarousels)
            refreshToken = UUID()
        } catch {
            Logger.warning("[DiscoveryViewModel] Failed to load global filters from database: \(error.localizedDescription)")
        }
    }

    private func persistGlobalFilters() async {
        guard let userId = AuthService.shared.currentUser?.id else {
            return
        }

        let deviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") ?? "unknown"
        let now = ISO8601DateFormatter().string(from: Date())

        let mediaType: String? = {
            switch globalFilters.mediaType {
            case .movies: return "movie"
            case .tvShows: return "tv"
            case .both: return "both"
            }
        }()

        let runtime = globalFilters.getRuntimeRange()
        let rating = globalFilters.getRatingRange()
        let years = globalFilters.getYearRange()

        let countriesJSON: String? = {
            guard !globalFilters.countries.isEmpty else { return nil }
            let arr = globalFilters.countries
            if let data = try? JSONSerialization.data(withJSONObject: arr),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return nil
        }()

        let sortBy: String = {
            switch globalFilters.sortBy {
            case .ratingAsc, .ratingDesc: return "rating"
            case .releaseDateAsc, .releaseDateDesc: return "release_date"
            default: return "popularity"
            }
        }()

        let sqliteRow: [String: Any] = [
            "user_id": userId,
            "device_id": deviceId,
            "media_type": mediaType ?? NSNull(),
            "runtime_min": runtime.min ?? NSNull(),
            "runtime_max": runtime.max ?? NSNull(),
            "rating_min": rating.min ?? NSNull(),
            "rating_max": rating.max ?? NSNull(),
            "release_year_start": years.start ?? NSNull(),
            "release_year_end": years.end ?? NSNull(),
            "countries": countriesJSON ?? NSNull(),
            "sort_by": sortBy,
            "hide_watched": globalFilters.hideWatched,
            "hide_disliked": globalFilters.hideDisliked,
            "updated_at": now
        ]

        do {
            try await sqliteService.upsert(table: "global_discovery_filters", rows: [sqliteRow])

            let supabaseRow: [String: Any] = sqliteRow.merging([
                "countries": globalFilters.countries.isEmpty ? NSNull() : globalFilters.countries
            ]) { _, new in new }

            do {
                try await SyncEngine.shared.queueOperation(
                    table: "global_discovery_filters",
                    operationType: "UPSERT",
                    recordId: userId,
                    payload: supabaseRow,
                    dependsOn: nil
                )
            } catch {
                Logger.error("[DiscoveryViewModel] Failed to queue filter sync: \(error)")
            }
        } catch {
            Logger.warning("[DiscoveryViewModel] Failed to persist global filters: \(error.localizedDescription)")
        }
    }
}
