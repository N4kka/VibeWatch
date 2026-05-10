import Foundation

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

    func items(for filter: TVTrackingFilter) -> [MediaListItem] {
        switch filter {
        case .continuing: return continuing
        case .notStarted: return notStarted
        case .upToDate: return upToDate
        }
    }
}
