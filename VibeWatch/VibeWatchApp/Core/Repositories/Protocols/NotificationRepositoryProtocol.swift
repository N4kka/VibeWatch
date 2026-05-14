import Foundation

protocol NotificationRepositoryProtocol {
    func toggleAlert(mediaId: Int, mediaType: MediaType, enabled: Bool) async throws
}
