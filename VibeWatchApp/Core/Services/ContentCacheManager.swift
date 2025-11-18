import Foundation

@MainActor
class ContentCacheManager: ObservableObject {
    static let shared = ContentCacheManager()
    
    @Published var cachedClips: [Clip] = []
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
    
    // MARK: - Clips Pre-loading
    
    func preloadClips() async {
        guard cachedClips.isEmpty else {
            print("⏭️ Skipping pre-load: \(cachedClips.count) clips already cached")
            return
        }
        
        print("🚀 Starting clips pre-load from Discovery trending...")
        isPreloadingClips = true
        
        do {
            // SMART: Use Discovery's already-fetched trending data!
            let tmdbService = TMDBService.shared
            let algorithmEngine = await ClipsAlgorithmEngine.shared
            
            // Get trending movies (already cached in Discovery)
            let moviesResponse = try await tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
            
            var clips: [Clip] = []
            var tried = 0
            
            // Try to get 5 clips from top trending movies
            for movie in moviesResponse.results.prefix(10) {
                tried += 1
                
                if let enhancedClips = try? await algorithmEngine.fetchBestClipForMovie(movie),
                   let clip = enhancedClips.first {
                    clips.append(clip.clip)
                    print("✅ Cached clip \(clips.count) from: \(movie.title)")
                    
                    if clips.count >= 5 {
                        print("🎯 Target reached: 5 clips from Discovery!")
                        break
                    }
                }
            }
            
            cachedClips = clips
            
            // Save to UserDefaults
            if let clipsData = try? JSONEncoder().encode(clips) {
                userDefaults.set(clipsData, forKey: cachedClipsKey)
                print("💾 Saved \(clips.count) clips to cache")
            }
            
            print("✅ Pre-load complete: \(clips.count) clips ready (tried \(tried) movies)")
        } catch {
            print("❌ Error pre-loading clips: \(error)")
        }
        
        isPreloadingClips = false
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
