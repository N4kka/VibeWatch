import Foundation

protocol TVTrackingRepositoryProtocol {
    func fetchBuckets() async -> TVTrackingBuckets
}

struct TVTrackingBuckets {
    var continuing: [MediaListItem] = []
    var notStarted: [MediaListItem] = []
    var upToDate: [MediaListItem] = []
}
