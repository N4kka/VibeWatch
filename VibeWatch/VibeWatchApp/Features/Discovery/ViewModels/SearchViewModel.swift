import Foundation
import Combine

struct VisitedItem: Codable, Equatable {
    let id: Int
    let mediaType: String // "movie" or "tv"
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
    @Published var trendingSearches: [SearchResult] = []
    @Published var latestVisitedItems: [SearchResult] = []
    @Published var isLoading = false
    @Published var error: AppError?
    
    /// Vero mentre si carica una pagina successiva: la lista continua, in fondo gira una rotella.
    @Published private(set) var isLoadingMore = false

    private var searchTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var currentPage = 1
    private var totalPages = 1
    /// `"mediaType:id"` di ciò che è già in lista: TMDB ripete gli stessi titoli fra le pagine.
    private var seenKeys = Set<String>()
    private let tmdbService: any TMDBServiceProtocol
    private let localSearch: any LocalTitleSearching
    private let preferenceManager: UserPreferenceManager
    private let visitedItemsKey = "latestVisitedItems" // UserDefaults key
    /// Il carosello degli ultimi visitati ne mostra una fila: con due voci non era un carosello.
    private let maxVisitedItems = 10
    private var lastLoggedQuery: String?
    private var lastLoggedAt: Date?

    init(
        tmdbService: any TMDBServiceProtocol = TMDBService.shared,
        localSearch: any LocalTitleSearching = SQLiteLocalTitleSearch(),
        preferenceManager: UserPreferenceManager = .shared
    ) {
        self.tmdbService = tmdbService
        self.localSearch = localSearch
        self.preferenceManager = preferenceManager
        Logger.debug("[SearchViewModel] init() called")
        self.loadTrendingSearches()
        Task { await self.loadLatestVisitedItems() }
    }

    deinit {
        searchTask?.cancel()
        loadMoreTask?.cancel()
    }

    func search() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        isLoadingMore = false
        currentPage = 1
        totalPages = 1
        seenKeys.removeAll()

        let currentQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentQuery.isEmpty else {
            searchResults = []
            isLoading = false
            error = nil
            return
        }

        isLoading = true
        error = nil

        searchTask = Task {
            // Cached titles first, with no debounce and no network: something relevant is on
            // screen from the first keystroke instead of an empty view for 350 ms + a round trip.
            // Overwritten below as soon as TMDB answers.
            let local = await localSearch.search(matching: currentQuery, limit: 20)
            guard !Task.isCancelled else { return }
            if !local.isEmpty {
                // Anche i risultati locali passano dal ranking: l'ordine non deve cambiare
                // criterio a metà, prima per cache e poi per rilevanza.
                searchResults = SearchRanking.rank(local, query: currentQuery)
            }

            // Debounce input so we don't spam both TMDB and search-history logging.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            do {
                let response = try await tmdbService.searchMulti(query: currentQuery, page: 1)
                if !Task.isCancelled {
                    let filtered = response.results.filter { result in
                        result.mediaType == "movie" || result.mediaType == "tv"
                    }
                    seenKeys = Set(filtered.map(Self.key))
                    currentPage = response.page
                    totalPages = response.totalPages
                    searchResults = SearchRanking.rank(filtered, query: currentQuery)
                    await logSearchIfNeeded(query: currentQuery, resultCount: searchResults.count)
                }
            } catch {
                if !Task.isCancelled {
                    self.error = AppError.network(error)
                }
            }
            
            isLoading = false
        }
    }

    /// Carica la pagina successiva quando l'utente arriva in fondo.
    ///
    /// La ricerca era ferma alla prima pagina: venti risultati e basta, senza che niente dicesse
    /// che ce n'erano altri. Qui la lista continua finché TMDB ha pagine.
    func loadMoreIfNeeded(currentItem: SearchResult) {
        guard !isLoadingMore, currentPage < totalPages else { return }
        // Solo quando l'item è fra gli ultimi cinque: caricare a metà lista è banda sprecata.
        let soglia = max(0, searchResults.count - 5)
        guard let index = searchResults.firstIndex(where: { Self.key($0) == Self.key(currentItem) }),
              index >= soglia else { return }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isLoadingMore = true
        let pagina = currentPage + 1

        loadMoreTask = Task {
            defer { isLoadingMore = false }
            do {
                let response = try await tmdbService.searchMulti(query: query, page: pagina)
                guard !Task.isCancelled else { return }
                // La query può essere cambiata mentre la pagina era in volo: quei risultati
                // appartengono a una ricerca che non esiste più.
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }

                let nuovi = response.results
                    .filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
                    .filter { seenKeys.insert(Self.key($0)).inserted }

                currentPage = response.page
                totalPages = response.totalPages
                // Re-rank dell'intero accumulato: una pagina nuova può contenere un match
                // migliore di quelli già mostrati.
                searchResults = SearchRanking.rank(searchResults + nuovi, query: query)
            } catch {
                // Una pagina in più che non arriva non è un errore da schermo: la lista che c'è
                // resta buona, e il prossimo scroll riprova.
                Logger.warning("[SearchViewModel] pagina \(pagina) non caricata: \(error)")
            }
        }
    }

    private static func key(_ result: SearchResult) -> String {
        "\(result.mediaType):\(result.id)"
    }

    func handleResultTap(_ result: SearchResult) {
        saveVisitedItem(id: result.id, mediaType: result.mediaType)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        Task {
            await preferenceManager.recordSearchClick(
                query: query,
                clickedMediaId: result.id,
                clickedMediaTitle: result.displayTitle,
                clickedMediaType: result.mediaType,
                resultCount: searchResults.count
            )
        }
    }

    private func logSearchIfNeeded(query: String, resultCount: Int) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else { return }

        if let last = lastLoggedQuery, last == normalized,
           let lastAt = lastLoggedAt,
           Date().timeIntervalSince(lastAt) < 10 {
            return
        }

        lastLoggedQuery = normalized
        lastLoggedAt = Date()

        await preferenceManager.recordSearchQuery(
            query: normalized,
            mediaType: nil,
            resultCount: resultCount
        )
    }
    
    func saveVisitedItem(id: Int, mediaType: String) {
        var items = getVisitedItems()
        let newItem = VisitedItem(id: id, mediaType: mediaType)
        
        // Remove if already exists to move to top
        items.removeAll { $0 == newItem }
        
        // Add to front
        items.insert(newItem, at: 0)
        
        // Keep only the latest ones
        if items.count > maxVisitedItems {
            items = Array(items.prefix(maxVisitedItems))
        }
        
        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: visitedItemsKey)
        }
        
        // Reload published property
        Task { await loadLatestVisitedItems() } // Reload after saving
    }

    /// Svuota gli ultimi visitati: è cronologia dell'utente, deve poter sparire su richiesta.
    func clearVisitedItems() {
        UserDefaults.standard.removeObject(forKey: visitedItemsKey)
        latestVisitedItems = []
    }

    private func getVisitedItems() -> [VisitedItem] {
        if let savedItemsData = UserDefaults.standard.data(forKey: visitedItemsKey),
           let decodedItems = try? JSONDecoder().decode([VisitedItem].self, from: savedItemsData) {
            return decodedItems
        }
        return []
    }
    
    func loadLatestVisitedItems() async {
        let storedItems = getVisitedItems()
        var loadedResults: [SearchResult] = []
        
        await withTaskGroup(of: SearchResult?.self) { group in
            for item in storedItems {
                group.addTask {
                    do {
                        if item.mediaType == "movie" {
                            let movie = try await self.tmdbService.getMovieDetails(id: item.id)
                            return SearchResult(
                                id: movie.id,
                                mediaType: "movie",
                                title: movie.title,
                                name: nil,
                                overview: movie.overview,
                                posterPath: movie.posterPath,
                                backdropPath: movie.backdropPath,
                                releaseDate: movie.releaseDate,
                                firstAirDate: nil,
                                voteAverage: movie.voteAverage,
                                voteCount: movie.voteCount,
                                popularity: movie.popularity
                            )
                        } else if item.mediaType == "tv" {
                            let tvShow = try await self.tmdbService.getTVShowDetails(id: item.id)
                            return SearchResult(
                                id: tvShow.id,
                                mediaType: "tv",
                                title: nil,
                                name: tvShow.name,
                                overview: tvShow.overview,
                                posterPath: tvShow.posterPath,
                                backdropPath: tvShow.backdropPath,
                                releaseDate: nil,
                                firstAirDate: tvShow.firstAirDate,
                                voteAverage: tvShow.voteAverage,
                                voteCount: tvShow.voteCount,
                                popularity: tvShow.popularity
                            )
                        }
                    } catch {
                        Logger.warning("[SearchViewModel] Error loading visited item \(item.id) (\(item.mediaType)): \(error)")
                    }
                    return nil
                }
            }
            
            for await result in group {
                if let result = result {
                    loadedResults.append(result)
                }
            }
        }
        
        // Ensure the order is preserved (most recent first)
        latestVisitedItems = storedItems.compactMap { storedItem in
            loadedResults.first { $0.id == storedItem.id && $0.mediaType == storedItem.mediaType }
        }
    }
    
    // MARK: - Trending
    
    func loadTrendingSearches() {
        Task {
            do {
                async let trendingMovies = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
                async let trendingTV = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
                
                let (moviesRes, tvRes) = try await (trendingMovies, trendingTV)
                
                // Map movies to SearchResult
                let movieResults: [SearchResult] = moviesRes.results.map { movie in
                    SearchResult(
                        id: movie.id,
                        mediaType: "movie",
                        title: movie.title,
                        name: nil,
                        overview: movie.overview,
                        posterPath: movie.posterPath,
                        backdropPath: movie.backdropPath,
                        releaseDate: movie.releaseDate,
                        firstAirDate: nil,
                        voteAverage: movie.voteAverage,
                        voteCount: movie.voteCount,
                        popularity: movie.popularity
                    )
                }
                
                // Map TV shows to SearchResult
                let tvResults: [SearchResult] = tvRes.results.map { tv in
                    SearchResult(
                        id: tv.id,
                        mediaType: "tv",
                        title: nil,
                        name: tv.name,
                        overview: tv.overview,
                        posterPath: tv.posterPath,
                        backdropPath: tv.backdropPath,
                        releaseDate: nil,
                        firstAirDate: tv.firstAirDate,
                        voteAverage: tv.voteAverage,
                        voteCount: tv.voteCount,
                        popularity: tv.popularity
                    )
                }
                
                // Combine and limit if desired
                let combined = Array((movieResults + tvResults).prefix(20))
                trendingSearches = combined
            } catch {
                self.error = AppError.network(error)
            }
        }
    }
}
