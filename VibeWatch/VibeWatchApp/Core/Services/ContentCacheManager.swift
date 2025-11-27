import Foundation

@MainActor
class ContentCacheManager: ObservableObject {
    static let shared = ContentCacheManager()
    
    // Made internal so ClipsRepository can access it
    var cachedClips: [Clip] = []
    @Published var isPreloadingClips = false
    
    private let userDefaults = UserDefaults.standard
    private let clipsService = ClipsService.shared
    
    // Keys for UserDefaults
    private let lastUpdateDateKey = "lastDiscoveryUpdateDate"
    private let cachedMoviesKey = "cachedDiscoveryMovies"
    private let cachedTVShowsKey = "cachedDiscoveryTVShows"
    private let cachedClipsKey = "cachedClips"
    
    private init() {
        loadCachedClips()
    }
    
    // MARK: - Daily Discovery Content
    
    func shouldUpdateDiscoveryContent() -> Bool {
        guard let lastUpdate = userDefaults.object(forKey: lastUpdateDateKey) as? Date else {
            return true // First time
        }
        
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastUpdateDay = calendar.startOfDay(for: lastUpdate)
        
        return today > lastUpdateDay
    }
    
    func getCachedDiscoveryMovies() -> [Movie]? {
        guard !shouldUpdateDiscoveryContent(),
              let data = userDefaults.data(forKey: cachedMoviesKey),
              let movies = try? JSONDecoder().decode([Movie].self, from: data) else {
            return nil
        }
        return movies
    }
    
    func getCachedDiscoveryTVShows() -> [Movie]? {
        guard !shouldUpdateDiscoveryContent(),
              let data = userDefaults.data(forKey: cachedTVShowsKey),
              let tvShows = try? JSONDecoder().decode([Movie].self, from: data) else {
            return nil
        }
        return tvShows
    }
    
    func cacheDiscoveryContent(movies: [Movie], tvShows: [Movie]) {
        // Shuffle for randomness
        let shuffledMovies = movies.shuffled()
        let shuffledTVShows = tvShows.shuffled()
        
        // Save to UserDefaults
        if let moviesData = try? JSONEncoder().encode(shuffledMovies) {
            userDefaults.set(moviesData, forKey: cachedMoviesKey)
        }
        
        if let tvShowsData = try? JSONEncoder().encode(shuffledTVShows) {
            userDefaults.set(tvShowsData, forKey: cachedTVShowsKey)
        }
        
        // Update last update date
        userDefaults.set(Date(), forKey: lastUpdateDateKey)
    }
    
    // MARK: - Shared Preload Logic (The "One Source of Truth")
    
    /// Orchestrates the main app launch preload:
    /// 1. Fetches Trending Movies (used by BOTH Discovery & Clips)
    /// 2. Picks top 5 movies and preloads clips in parallel
    /// 3. Caches everything
    func performSmartPreload() async {
        print("🚀 START: Unified Smart Preload")
        let startTime = Date()
        
        do {
            // Step 1: Fetch Trending Movies (Source of Truth)
            let moviesResponse = try await TMDBService.shared.getTrendingMovies(timeWindow: .week, page: 1)
            let movies = moviesResponse.results
            
            // Step 2: Cache for Discovery View (so it doesn't re-fetch)
            // We store this in memory/disk so DiscoveryViewModel can pick it up instantly
            if let moviesData = try? JSONEncoder().encode(movies) {
                userDefaults.set(moviesData, forKey: cachedMoviesKey)
                userDefaults.set(Date(), forKey: lastUpdateDateKey) // Mark as fresh
            }
            print("✅ Step 1: Cached \(movies.count) trending movies for Discovery")
            
            // Step 3: Preload 5 Clips from these SAME movies (Parallel)
            // This ensures the first 5 clips match the "Trending" vibe and load instantly
                        let preloadedClips = await QuickClipsService.shared.preloadClips(from: movies, count: 5)            
            // Store in memory for immediate access
            self.cachedClips = preloadedClips
            
            // Persist backup
            if let clipsData = try? JSONEncoder().encode(preloadedClips) {
                userDefaults.set(clipsData, forKey: cachedClipsKey)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            print("✅ PRELOAD COMPLETE in \(String(format: "%.3f", duration))s")
            
        } catch {
            print("❌ Preload failed: \(error.localizedDescription)")
        }
        
        isPreloadingClips = false
    }

    // MARK: - Clips Pre-loading (Legacy/Fallback)
    
    func preloadClips() async {
        await performSmartPreload()
    }
    
    private func loadCachedClips() {
        guard let data = userDefaults.data(forKey: cachedClipsKey),
              let clips = try? JSONDecoder().decode([Clip].self, from: data) else {
            return
        }
        cachedClips = clips
        print("✅ Loaded \(clips.count) cached clips from storage")
    }
    
    func clearClipsCache() {
        cachedClips = []
        userDefaults.removeObject(forKey: cachedClipsKey)
    }
}
