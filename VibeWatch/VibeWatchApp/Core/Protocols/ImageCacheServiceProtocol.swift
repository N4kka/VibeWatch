import Foundation
import UIKit

/// Protocol defining the image cache service interface.
/// Enables testability through dependency injection and mocking.
protocol ImageCacheServiceProtocol: AnyObject {
    // MARK: - Image Loading

    func loadImage(from urlString: String) async throws -> UIImage
    func prefetchImages(_ urls: [String], onWiFiOnly: Bool) async

    // MARK: - Cache Management

    func clearCache()
    func getCacheStats() -> (memoryUsage: Int, diskUsage: Int)
    func cleanupOldCache()

    // MARK: - Preferences

    func setCacheSizePreference(_ preference: ImageCacheService.CacheSizePreference)
    func setImagePrefetchOption(_ option: ImageCacheService.ImagePrefetchOption)
    func getCurrentImagePrefetchOption() -> ImageCacheService.ImagePrefetchOption
    func getCurrentCacheSizePreference() -> ImageCacheService.CacheSizePreference
    func shouldPrefetchImages(preference: ImageCacheService.ImagePrefetchOption) async -> Bool
}
