import Foundation

@MainActor
final class ClipsSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var matches: [Clip] = []
    @Published var related: [Clip] = []
    @Published var isLoading = false
    @Published var error: AppError?
    @Published var currentIndex: Int = 0
    @Published var hasSearched = false
    
    var clips: [Clip] {
        matches + related
    }
    
    private let searchService: ClipsSearchService
    private let clipsService: ClipsService
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    
    init(searchService: ClipsSearchService = .shared, clipsService: ClipsService = .shared) {
        self.searchService = searchService
        self.clipsService = clipsService
    }

    deinit {
        searchTask?.cancel()
        debounceTask?.cancel()
    }

    func updateQuery(_ text: String) {
        query = text
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }
    
    func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            reset()
            return
        }
        
        hasSearched = true
        searchTask?.cancel()
        isLoading = true
        error = nil
        
        searchTask = Task { [weak self] in
            guard let self else { return }
            
            do {
                let result = try await searchService.search(query: trimmed)
                guard !Task.isCancelled else { return }
                
                self.matches = result.matches
                self.related = result.related
                self.currentIndex = 0
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                if let appError = error as? AppError {
                    self.error = appError
                } else {
                    self.error = .unknown(error)
                }
                self.isLoading = false
            }
        }
    }
    
    func loadShowcaseClips() async {
        guard !hasSearched && clips.isEmpty else { return }
        
        isLoading = true
        error = nil
        
        do {
            let showcaseClips = try await clipsService.fetchTrendingClips(page: 1, limit: 20)
            matches = Array(showcaseClips.prefix(10))
            related = Array(showcaseClips.dropFirst(10).prefix(10))
            currentIndex = 0
            isLoading = false
        } catch {
            if let appError = error as? AppError {
                self.error = appError
            } else {
                self.error = .unknown(error)
            }
            isLoading = false
        }
    }
    
    func reset() {
        searchTask?.cancel()
        debounceTask?.cancel()
        matches = []
        related = []
        error = nil
        isLoading = false
        currentIndex = 0
        hasSearched = false
    }
    
    func toggleLike(for clipId: String, isLiked: Bool) {
        updateLike(in: &matches, clipId: clipId, isLiked: isLiked)
        updateLike(in: &related, clipId: clipId, isLiked: isLiked)
        
        Task {
            do {
                try await ClipsService.shared.updateLikeStatus(clipId: clipId, isLiked: isLiked)
            } catch {
                Logger.error("[ClipsSearchViewModel] Failed to update like status: \(error.localizedDescription)")
            }
        }
    }
    
    private func updateLike(in collection: inout [Clip], clipId: String, isLiked: Bool) {
        if let index = collection.firstIndex(where: { $0.id == clipId }) {
            var updated = collection[index]
            updated.isLiked = isLiked
            updated.likes = max(0, updated.likes + (isLiked ? 1 : -1))
            collection[index] = updated
            
            ClipsService.shared.updateLikeCount(clipId: clipId, newCount: updated.likes)
        }
    }
}
