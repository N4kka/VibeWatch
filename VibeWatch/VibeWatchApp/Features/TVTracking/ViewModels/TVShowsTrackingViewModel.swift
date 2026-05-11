import Foundation
import Combine

enum TVTrackingFilter: String, CaseIterable {
    case continuing = "tvTracking.continuing"
    case notStarted = "tvTracking.notStarted"
    case upToDate = "tvTracking.upToDate"

    var displayName: String {
        rawValue.localizedMainSafe()
    }
}

@MainActor
class TVShowsTrackingViewModel: ObservableObject {
    @Published var continuing: [MediaListItem] = []
    @Published var notStarted: [MediaListItem] = []
    @Published var upToDate: [MediaListItem] = []
    @Published var isLoading = false

    private let repository: any TVTrackingRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(repository: LiveTVTrackingRepository.shared)
    }

    init(repository: any TVTrackingRepositoryProtocol) {
        self.repository = repository
        
        Publishers.Merge3(
            ListManager.shared.$lists.map { _ in () },
            EpisodeSeenManager.shared.$seenKeys.map { _ in () },
            EpisodeSeenManager.shared.$seenShowIds.map { _ in () }
        )
        .dropFirst()
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            Task {
                await self?.load()
            }
        }
        .store(in: &cancellables)
    }

    func load() async {
        isLoading = true
        let buckets = await repository.fetchBuckets()
        continuing = buckets.continuing
        notStarted = buckets.notStarted
        upToDate = buckets.upToDate
        isLoading = false
    }

    func items(for filter: TVTrackingFilter) -> [MediaListItem] {
        switch filter {
        case .continuing: return continuing
        case .notStarted: return notStarted
        case .upToDate: return upToDate
        }
    }
}
