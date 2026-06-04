import Foundation

/// Pure filter + sort for list items (Fase 5 — logica fuori dalla View, testabile).
///
/// Estratta da `ListsView` dove era DUPLICATA in due struct quasi identici. La sola
/// differenza era che la list-detail principale applicava il filtro periodo/anno e la
/// `CustomListDetailView` no (omissione copia-incolla) → reso esplicito da
/// `applyReleasePeriodFilter` per preservare il comportamento esatto di ciascun chiamante.
///
/// È pura: la disponibilità streaming (che nella View viene da `ListAvailabilityService`)
/// è iniettata come mappa `availabilityByItemId` (itemID → set di piattaforme).
enum ListItemFilterer {

    static func filteredAndSorted(
        _ items: [MediaListItem],
        searchText: String,
        filters: GlobalDiscoveryFilters,
        availabilityByItemId: [String: Set<String>],
        applyReleasePeriodFilter: Bool
    ) -> [MediaListItem] {
        var items = items

        // Search
        if !searchText.isEmpty {
            items = items.filter { $0.title.range(of: searchText, options: .caseInsensitive) != nil }
        }

        // Runtime (movies only)
        if filters.runtimePreset != .any || filters.customRuntimeMin != nil || filters.customRuntimeMax != nil {
            let (min, max) = filters.getRuntimeRange()
            items = items.filter { item in
                guard item.mediaType == .movie, let runtime = item.runtime else { return false }
                if let minRuntime = min, runtime < minRuntime { return false }
                if let maxRuntime = max, runtime > maxRuntime { return false }
                return true
            }
        }

        // Rating
        if filters.ratingPreset != .any || filters.customRatingMin != nil || filters.customRatingMax != nil {
            let (min, max) = filters.getRatingRange()
            items = items.filter { item in
                guard let voteAverage = item.voteAverage else { return false }
                if let minRating = min, voteAverage < minRating { return false }
                if let maxRating = max, voteAverage > maxRating { return false }
                return true
            }
        }

        // Release period (year) — opt-in per preservare il comportamento dei due chiamanti
        if applyReleasePeriodFilter,
           filters.releasePeriodPreset != .any || filters.customYearStart != nil || filters.customYearEnd != nil {
            let (start, end) = filters.getYearRange()
            items = items.filter { item in
                guard let releaseDate = item.releaseDate, let year = Int(releaseDate.prefix(4)) else { return false }
                if let startYear = start, year < startYear { return false }
                if let endYear = end, year > endYear { return false }
                return true
            }
        }

        // Country
        if !filters.countries.isEmpty {
            items = items.filter { item in
                guard let originCountry = item.originCountry else { return false }
                return !Set(originCountry).isDisjoint(with: Set(filters.countries))
            }
        }

        // Streaming platforms (availability injected → pure)
        if !filters.streamingPlatforms.isEmpty {
            items = items.filter { item in
                guard let availableOn = availabilityByItemId[item.id] else { return false }
                return !availableOn.isDisjoint(with: filters.streamingPlatforms)
            }
        }

        // Media type
        switch filters.mediaType {
        case .both:
            break
        case .movies:
            items = items.filter { $0.mediaType == .movie }
        case .tvShows:
            items = items.filter { $0.mediaType == .tv }
        }

        // Sort
        switch filters.sortBy {
        case .popularityDesc, .popularityAsc:
            // Nessun dato di popolarità memorizzato → fallback su data di aggiunta.
            items.sort { $0.addedAt > $1.addedAt }
        case .ratingDesc:
            items.sort { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
        case .ratingAsc:
            items.sort { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }
        case .releaseDateDesc:
            items.sort { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        case .releaseDateAsc:
            items.sort { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
        }

        return items
    }
}
