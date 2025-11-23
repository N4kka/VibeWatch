import Foundation
import SwiftUI

/// Optimized ClipsViewModel - Uses DatabaseClipsService with smart caching
@MainActor
class ClipsViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let databaseClipsService = DatabaseClipsService.shared
    private let engagementTracker = UserEngagementTracker.shared
    private let prefetchService = ClipsPrefetchService.shared
    private let dataCoordinator = DataCoordinator.shared
    
    private var isLoadingMore = false
    private var loadStartTime: Date?
    private var hasUsedPreloadedClips = false
    
    // MARK: - Smart Loading (Pre-loaded clips first, then database)
    
    /// Load clips with minimum 2-second loading screen for better UX
    func loadClips() async {
        guard !isLoading else { return }
        
        isLoading = true
        loadStartTime = Date()
        print("🎬 [ClipsViewModel] Loading clips...")
        
        do {
            // STEP 1: Check for pre-loaded clips from DataCoordinator (INSTANT!)
            if !hasUsedPreloadedClips && !dataCoordinator.initialClips.isEmpty {
                print("⚡️ [ClipsViewModel] Using \(dataCoordinator.initialClips.count) pre-loaded clips!")
                
                // Get initial clips + additional clips if ready
                var allPreloadedClips = dataCoordinator.initialClips
                if !dataCoordinator.additionalClips.isEmpty {
                    allPreloadedClips += dataCoordinator.additionalClips
                    print("   + \(dataCoordinator.additionalClips.count) additional clips")
                }
                
                // Apply like status
                let processedClips = allPreloadedClips.map { clip in
                    var updatedClip = clip
                    updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                    return updatedClip
                }
                
                // Ensure minimum 2-second loading time for UX
                await ensureMinimumLoadingTime()
                
                self.clips = processedClips
                hasUsedPreloadedClips = true
                
                print("✅ [ClipsViewModel] Displayed \(clips.count) pre-loaded clips instantly!")
                
                // Continue fetching from database in background for more variety
                Task {
                    await loadMoreFromDatabase()
                }
                
                isLoading = false
                return
            }
            
            // STEP 2: Fallback to database if no pre-loaded clips
            print("🔍 [ClipsViewModel] No pre-loaded clips, fetching from database...")
            
            // Check if we need to prefetch clips today
            if prefetchService.shouldFetchToday() {
                print("📅 [ClipsViewModel] Triggering daily clips pre-fetch...")
                Task {
                    try? await prefetchService.prefetchClips(targetCount: 800)
                }
            }
            
            // Fetch 20 clips from database/API
            let fetchedClips = try await databaseClipsService.fetchPersonalizedClips(count: 20)
            
            print("📦 [ClipsViewModel] Received \(fetchedClips.count) clips from database")
            
            if fetchedClips.isEmpty {
                print("⚠️ [ClipsViewModel] No clips returned from service!")
                errorMessage = "No clips available. Please try again."
                await ensureMinimumLoadingTime()
                isLoading = false
                return
            }
            
            // Apply like status
            let processedClips = fetchedClips.map { clip in
                var updatedClip = clip
                updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                return updatedClip
            }
            
            // Ensure minimum 2-second loading time for UX
            await ensureMinimumLoadingTime()
            
            self.clips = processedClips
            print("✅ [ClipsViewModel] Successfully loaded \(clips.count) clips from database")
            
        } catch {
            print("❌ [ClipsViewModel] Error loading clips: \(error)")
            errorMessage = "Failed to load clips: \(error.localizedDescription)"
            
            // Ensure minimum loading time even on error
            await ensureMinimumLoadingTime()
        }
        
        isLoading = false
    }
    
    /// Load more clips from database in background (after pre-loaded clips are shown)
    private func loadMoreFromDatabase() async {
        print("🔄 [ClipsViewModel] Loading more from database in background...")
        
        do {
            let fetchedClips = try await databaseClipsService.fetchPersonalizedClips(count: 20)
            
            if !fetchedClips.isEmpty {
                let processedClips = fetchedClips.map { clip in
                    var updatedClip = clip
                    updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                    return updatedClip
                }
                
                // Append to existing clips (don't replace)
                self.clips.append(contentsOf: processedClips)
                print("✅ [ClipsViewModel] Added \(processedClips.count) more clips (total: \(clips.count))")
            }
        } catch {
            print("⚠️ [ClipsViewModel] Background fetch failed: \(error)")
        }
    }
    
    /// Ensure loading screen shows for minimum 2 seconds
    private func ensureMinimumLoadingTime() async {
        guard let startTime = loadStartTime else { return }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let minimumDuration: TimeInterval = 2.0
        
        if elapsed < minimumDuration {
            let remainingTime = minimumDuration - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
            print("⏱️ [ClipsViewModel] Extended loading for better UX (+\(remainingTime)s)")
        }
    }
    
    /// Pre-load additional clips in background
    private func preloadMoreClips() async {
        do {
            let moreClips = try await databaseClipsService.fetchPersonalizedClips(count: 15)
            print("🔄 [ClipsViewModel] Pre-fetched \(moreClips.count) additional clips")
            // We'll append these when user scrolls
        } catch {
            print("⚠️ [ClipsViewModel] Pre-fetch error: \(error)")
        }
    }
    
    /// Refresh feed - reset and reload
    func refreshFeed() async {
        print("🔄 [ClipsViewModel] Refreshing feed...")
        clips = []
        await loadClips()
    }
    
    // MARK: - Infinite Scroll
    
    /// Load more clips when user scrolls to bottom (pagination)
    func loadMoreClips() async {
        guard !isLoadingMore && !isLoading else { return }
        
        print("🎬 [ClipsViewModel] Loading more clips (pagination)...")
        isLoadingMore = true
        
        do {
            // Fetch next batch from database
            let moreClips = try await databaseClipsService.fetchPersonalizedClips(count: 20)
            
            // Apply like status
            let processedClips = moreClips.map { clip in
                var updatedClip = clip
                updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                return updatedClip
            }
            
            // Append to existing clips
            clips.append(contentsOf: processedClips)
            
            print("✅ [ClipsViewModel] Pagination: Added \(processedClips.count) clips. Total: \(clips.count)")
            
        } catch {
            print("⚠️ [ClipsViewModel] Pagination error: \(error)")
        }
        
        isLoadingMore = false
    }
    
    // MARK: - User Interaction Tracking (Taste Learning)
    
    /// Track when user starts watching a clip
    func startWatching(clip: Clip) {
        engagementTracker.startWatchingClip(clip)
        print("👁️ Started watching: \(clip.title)")
    }
    
    /// Track watch time and completion
    func updateWatchTime(clipId: String, watchedSeconds: Double, totalSeconds: Double) {
        engagementTracker.updateWatchTime(
            clipId: clipId,
            duration: watchedSeconds,
            totalDuration: totalSeconds
        )
    }
    
    /// Track when user leaves a clip
    func stopWatching(clipId: String) {
        engagementTracker.endWatchingClip(clipId: clipId)
        print("👋 Stopped watching clip")
    }
    
    /// Track when user likes a clip (interface for ClipsView)
    func toggleLike(for clipId: String, isLiked: Bool) {
        // Update UI immediately
        if let index = clips.firstIndex(where: { $0.id == clipId }) {
            var updatedClip = clips[index]
            updatedClip.isLiked = isLiked
            updatedClip.likes += isLiked ? 1 : -1
            clips[index] = updatedClip
            
            // Update service
            ClipsService.shared.updateLikeCount(clipId: clipId, newCount: updatedClip.likes)
            
            // Log for user taste learning
            if isLiked {
                print("❤️ Liked: \(updatedClip.title)")
            } else {
                print("💔 Unliked: \(updatedClip.title)")
            }
            
            // Persist like status
            Task {
                try? await ClipsService.shared.updateLikeStatus(clipId: clipId, isLiked: isLiked)
            }
        }
    }
    
    /// Track clip impressions (shown to user)
    private func trackClipImpressions(_ shownClips: [Clip]) {
        // Simple impression tracking - watch time is the primary signal
        print("📊 Showing \(shownClips.count) clips to user")
    }
    
    /// Track when user adds clip to list
    func trackAddToList(clip: Clip) {
        engagementTracker.trackListAddition(clip: clip, listType: "watchlist")
        print("📝 Added to list: \(clip.title)")
    }
}
