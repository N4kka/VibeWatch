import Foundation
import SwiftUI

/// Optimized ClipsViewModel - Uses DataCoordinator for efficient loading
@MainActor
class ClipsViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let dataCoordinator = DataCoordinator.shared
    private let engagementTracker = UserEngagementTracker.shared
    
    private var isLoadingMore = false
    
    // MARK: - Instant Loading (Uses Preloaded Clips)
    
    /// Load clips INSTANTLY - uses preloaded clips from DataCoordinator
    func loadClips() async {
        guard !isLoading else { return }
        
        print("🎬 [ClipsViewModel] Loading clips...")
        
        // Check if any clips are available (initial OR additional)
        let hasAnyClips = !dataCoordinator.initialClips.isEmpty || !dataCoordinator.additionalClips.isEmpty
        
        if hasAnyClips {
            // Use available clips immediately
            var allClips = dataCoordinator.initialClips + dataCoordinator.additionalClips
            
            // Apply like status
            allClips = allClips.map { clip in
                var updatedClip = clip
                updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                return updatedClip
            }
            
            self.clips = allClips
            print("✅ [ClipsViewModel] Ready: \(clips.count) clips (initial: \(dataCoordinator.initialClips.count), additional: \(dataCoordinator.additionalClips.count))")
            return
        }
        
        // Fallback: Wait for clips to load (initial or additional)
        print("⚠️ [ClipsViewModel] No clips ready, waiting for background fetch...")
        isLoading = true
        
        // Wait up to 10 seconds for clips (background task is fetching)
        var attempts = 0
        while dataCoordinator.initialClips.isEmpty && dataCoordinator.additionalClips.isEmpty && attempts < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            attempts += 1
        }
        
        // Get whatever clips are available
        let allClips = dataCoordinator.initialClips + dataCoordinator.additionalClips
        
        if !allClips.isEmpty {
            // Apply like status
            self.clips = allClips.map { clip in
                var updatedClip = clip
                updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                return updatedClip
            }
            
            print("✅ [ClipsViewModel] Loaded after wait: \(clips.count) clips")
        } else {
            print("❌ [ClipsViewModel] Failed to load clips after \(attempts * 100)ms")
            errorMessage = "Failed to load clips. Please try again."
        }
        
        isLoading = false
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
        
        // Fetch next batch from DataCoordinator (handles pagination)
        let moreClips = await dataCoordinator.fetchMoreClips(count: 20)
        
        // Apply like status
        let processedClips = moreClips.map { clip in
            var updatedClip = clip
            updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
            return updatedClip
        }
        
        // Append to existing clips
        clips.append(contentsOf: processedClips)
        
        print("✅ [ClipsViewModel] Pagination: Added \(processedClips.count) clips. Total: \(clips.count)")
        
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
    
    // MARK: - Utility
    
    /// Get stats for debugging
    func getStats() -> String {
        dataCoordinator.getStats()
    }
}
