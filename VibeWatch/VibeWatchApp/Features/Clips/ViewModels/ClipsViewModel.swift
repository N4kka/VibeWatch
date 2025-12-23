import Foundation
import SwiftUI

/// Optimized ClipsViewModel - Coordinates between the UI and the data layer (ClipsRepository)
@MainActor
class ClipsViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false
    @Published var error: AppError?
    @Published var currentIndex: Int = 0 // Persist current clip index across tab switches
    
    private let repository: ClipsRepository
    private let engagementTracker = UserEngagementTracker.shared
    private let prefetchService = ClipsPrefetchService.shared
    private let preferenceManager = UserPreferenceManager.shared
    private let tmdbService = TMDBService.shared

    private var watchMetrics: [String: (watched: Double, total: Double)] = [:]
    
    private var isLoadingMore = false
    private var loadStartTime: Date?
    private var hasLoadedInSession = false // Track if clips loaded in this app session
    
    init(repository: ClipsRepository? = nil) {
        // Avoid default-argument evaluation in nonisolated context by constructing here on the main actor
        self.repository = repository ?? ClipsRepository()
    }
    
    // MARK: - Data Loading
    
    /// Load initial set of clips, ensuring a smooth loading experience.
    func loadClips() async {
        guard !isLoading else { return }
        
        // Only show loading screen on first load in session
        if !hasLoadedInSession {
            isLoading = true
            loadStartTime = Date()
            Logger.info("🎬 [ClipsViewModel] Loading clips (first time in session)...")
        } else {
            Logger.info("🎬 [ClipsViewModel] Loading clips (already loaded in session, skipping loading screen)...")
        }
        
        do {
            // Check if we need to prefetch clips today
            if prefetchService.shouldFetchToday() {
                Logger.info("📅 [ClipsViewModel] Triggering daily clips pre-fetch...")
                Task {
                    try? await prefetchService.prefetchClips(targetCount: 800)
                }
            }
            
            // Fetch clips from the repository
            let fetchedClips = try await repository.fetchClips(count: 20)
            
            Logger.debug("📦 [ClipsViewModel] Received \(fetchedClips.count) clips from repository")
            
            if fetchedClips.isEmpty {
                Logger.warning("[ClipsViewModel] No clips returned from service!")
                self.error = AppError.noContentAvailable
            }
            
            // Ensure minimum loading time for better UX
            await ensureMinimumLoadingTime()
            
            self.clips = fetchedClips
            hasLoadedInSession = true // Mark as loaded in this session
            Logger.info("✅ [ClipsViewModel] Successfully loaded \(clips.count) clips")
            
        } catch {
            Logger.error("[ClipsViewModel] Error loading clips", error: error)
            self.error = AppError.database(error)
            await ensureMinimumLoadingTime()
        }
        
        isLoading = false
    }
    
    /// Load more clips for infinite scrolling.
    func loadMoreClips() async {
        guard !isLoadingMore && !isLoading else { return }
        
        Logger.info("🎬 [ClipsViewModel] Loading more clips (pagination)...")
        isLoadingMore = true
        
        do {
            // Fetch next batch from the repository
            let moreClips = try await repository.fetchClips(count: 20)
            
            // Append to existing clips
            clips.append(contentsOf: moreClips)
            
            Logger.info("✅ [ClipsViewModel] Pagination: Added \(moreClips.count) clips. Total: \(clips.count)")
            
        } catch {
            Logger.warning("[ClipsViewModel] Pagination error: \(error)")
        }
        
        isLoadingMore = false
    }

    /// Refresh feed - reset and reload
    func refreshFeed() async {
        Logger.info("🔄 [ClipsViewModel] Refreshing feed...")
        clips = []
        await loadClips()
    }
    
    /// Ensure loading screen shows for at least a minimum duration to avoid jarring UI flashes.
    private func ensureMinimumLoadingTime() async {
        guard let startTime = loadStartTime else { return }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let minimumDuration: TimeInterval = 2.0
        
        if elapsed < minimumDuration {
            let remainingTime = minimumDuration - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
            Logger.debug("⏱️ [ClipsViewModel] Extended loading for better UX (+\(remainingTime)s)")
        }
    }
    
    // MARK: - User Interaction Tracking
    
    func startWatching(clip: Clip) {
        engagementTracker.startWatchingClip(clip)
        Logger.debug("👁️ Started watching: \(clip.title)")
    }
    
    func updateWatchTime(clipId: String, watchedSeconds: Double, totalSeconds: Double) {
        watchMetrics[clipId] = (watchedSeconds, totalSeconds)
        engagementTracker.updateWatchTime(
            clipId: clipId,
            duration: watchedSeconds,
            totalDuration: totalSeconds
        )
    }
    
    func stopWatching(clipId: String) {
        guard let clip = clips.first(where: { $0.id == clipId }) else {
            engagementTracker.endWatchingClip(clipId: clipId)
            return
        }

        Task {
            let (genreIds, actorIds) = await fetchGenresAndActors(for: clip)
            engagementTracker.endWatchingClip(clipId: clipId, genres: genreIds, actors: actorIds)

            let score = engagementScore(for: clipId)
            recordUnifiedPreferences(for: clip, genreIds: genreIds, actorIds: actorIds, engagementScore: score, action: "watch")
        }
        Logger.debug("👋 Stopped watching clip")
    }
    
    func toggleLike(for clipId: String, isLiked: Bool) {
        if let index = clips.firstIndex(where: { $0.id == clipId }) {
            var updatedClip = clips[index]
            updatedClip.isLiked = isLiked
            updatedClip.likes += isLiked ? 1 : -1
            clips[index] = updatedClip
            
            ClipsService.shared.updateLikeCount(clipId: clipId, newCount: updatedClip.likes)
            
            if isLiked {
                Logger.debug("❤️ Liked: \(updatedClip.title)")
            } else {
                Logger.debug("💔 Unliked: \(updatedClip.title)")
            }
            
            Task {
                try? await ClipsService.shared.updateLikeStatus(clipId: clipId, isLiked: isLiked)

                let (genreIds, actorIds) = await fetchGenresAndActors(for: updatedClip)
                recordUnifiedPreferences(
                    for: updatedClip,
                    genreIds: genreIds,
                    actorIds: actorIds,
                    engagementScore: isLiked ? 5.0 : -1.0,
                    action: isLiked ? "like" : "unlike"
                )
            }
        }
    }
    
    func trackAddToList(clip: Clip) {
        engagementTracker.trackListAddition(clip: clip, listType: "watchlist")
        Logger.debug("📝 Added to list: \(clip.title)")

        Task {
            let (genreIds, actorIds) = await fetchGenresAndActors(for: clip)
            recordUnifiedPreferences(for: clip, genreIds: genreIds, actorIds: actorIds, engagementScore: 8.0, action: "add_to_list")
        }
    }

    // MARK: - Unified Preferences Integration

    private func recordUnifiedPreferences(
        for clip: Clip,
        genreIds: [Int],
        actorIds: [Int],
        engagementScore: Double,
        action: String
    ) {
        let mediaId = clip.movieId ?? clip.tvShowId
        guard let mediaId else { return }

        preferenceManager.recordInteraction(
            UserInteraction(
                source: .clips,
                mediaId: mediaId,
                mediaType: clip.inferredMediaType,
                genreIds: genreIds,
                actorIds: actorIds,
                engagementScore: engagementScore,
                metadata: [
                    "clip_id": clip.id,
                    "action": action
                ]
            )
        )
    }

    private func engagementScore(for clipId: String) -> Double {
        guard let metrics = watchMetrics[clipId], metrics.total > 0 else {
            return 0.0
        }

        let percentage = metrics.watched / metrics.total
        switch percentage {
        case 0..<0.1:
            return -1.0
        case 0.1..<0.25:
            return 0.0
        case 0.25..<0.5:
            return 1.0
        case 0.5..<0.8:
            return 3.0
        case 0.8...1.0:
            return 5.0
        default:
            return 0.0
        }
    }

    private func fetchGenresAndActors(for clip: Clip) async -> ([Int], [Int]) {
        guard let mediaId = clip.movieId ?? clip.tvShowId else {
            return ([], [])
        }

        do {
            if clip.inferredMediaType == .movie {
                let movie = try await tmdbService.getMovieDetails(id: mediaId)
                let credits = try? await tmdbService.getMovieCredits(id: mediaId)
                let genreIds = movie.genreIds ?? movie.genres?.map { $0.id } ?? []
                let actorIds = credits?.cast.prefix(5).map { $0.id } ?? []
                return (genreIds, actorIds)
            } else {
                let tv = try await tmdbService.getTVShowDetails(id: mediaId)
                let credits = try? await tmdbService.getTVShowCredits(id: mediaId)
                let genreIds = tv.genreIds ?? tv.genres?.map { $0.id } ?? []
                let actorIds = credits?.cast.prefix(5).map { $0.id } ?? []
                return (genreIds, actorIds)
            }
        } catch {
            Logger.warning("[ClipsViewModel] Failed to fetch TMDB metadata for clip: \(error.localizedDescription)")
            return ([], [])
        }
    }
}
