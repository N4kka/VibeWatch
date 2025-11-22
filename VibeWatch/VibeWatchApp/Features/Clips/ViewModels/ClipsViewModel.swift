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
    
    private var isLoadingMore = false
    private var loadStartTime: Date?
    
    // MARK: - Smart Loading (Database-First with 2s Minimum)
    
    /// Load clips with minimum 2-second loading screen for better UX
    func loadClips() async {
        guard !isLoading else { return }
        
        isLoading = true
        loadStartTime = Date()
        print("🎬 [ClipsViewModel] Loading clips...")
        
        // Check if we need to prefetch clips today
        if prefetchService.shouldFetchToday() {
            print("📅 [ClipsViewModel] Triggering daily clips pre-fetch...")
            Task {
                try? await prefetchService.prefetchClips(targetCount: 800)
            }
        }
        
        do {
            // Fetch 20 clips from database/API
            print("🔍 [ClipsViewModel] Calling fetchPersonalizedClips...")
            let fetchedClips = try await databaseClipsService.fetchPersonalizedClips(count: 20)
            
            print("📦 [ClipsViewModel] Received \(fetchedClips.count) clips from service")
            
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
            print("✅ [ClipsViewModel] Successfully loaded \(clips.count) personalized clips")
            
            // Pre-fetch next 15 in background
            Task {
                await preloadMoreClips()
            }
            
        } catch {
            print("❌ [ClipsViewModel] Error loading clips: \(error)")
            errorMessage = "Failed to load clips: \(error.localizedDescription)"
            
            // Ensure minimum loading time even on error
            await ensureMinimumLoadingTime()
        }
        
        isLoading = false
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
