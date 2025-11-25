import Foundation
import UIKit

/// Service for caching images offline
/// Uses URLCache for automatic caching with size limits
@MainActor
class ImageCacheService {
    static let shared = ImageCacheService()
    
    private let cache: URLCache
    private let session: URLSession
    
    // Cache configuration
    private let maxMemorySize = 100 * 1024 * 1024  // 100 MB in memory
    private let maxDiskSize = 500 * 1024 * 1024     // 500 MB on disk
    
    private init() {
        // Configure URLCache
        cache = URLCache(
            memoryCapacity: maxMemorySize,
            diskCapacity: maxDiskSize,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ImageCache")
        )
        
        // Configure URLSession with cache
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        
        session = URLSession(configuration: config)
        
        print("🖼️ [ImageCache] Initialized with \(maxMemorySize / 1024 / 1024)MB memory, \(maxDiskSize / 1024 / 1024)MB disk")
    }
    
    /// Load image from URL with caching
    func loadImage(from urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else {
            throw ImageCacheError.invalidURL
        }
        
        // Check if cached
        let request = URLRequest(url: url)
        if let cachedResponse = cache.cachedResponse(for: request),
           let image = UIImage(data: cachedResponse.data) {
            print("✅ [ImageCache] Loaded from cache: \(url.lastPathComponent)")
            return image
        }
        
        // Download image
        print("⬇️ [ImageCache] Downloading: \(url.lastPathComponent)")
        let (data, response) = try await session.data(from: url)
        
        guard let image = UIImage(data: data) else {
            throw ImageCacheError.invalidImageData
        }
        
        // Cache the response
        let cachedResponse = CachedURLResponse(response: response, data: data)
        cache.storeCachedResponse(cachedResponse, for: request)
        
        return image
    }
    
    /// Prefetch images for offline viewing (WiFi only)
    func prefetchImages(_ urls: [String], onWiFiOnly: Bool = true) async {
        guard !urls.isEmpty else { return }
        
        // Check network type if WiFi-only
        if onWiFiOnly {
            let isOnWiFi = await NetworkMonitor.shared.isOnWiFi()
            guard isOnWiFi else {
                print("⚠️ [ImageCache] Skipping prefetch - not on WiFi")
                return
            }
        }
        
        print("📥 [ImageCache] Prefetching \(urls.count) images...")
        
        await withTaskGroup(of: Void.self) { group in
            for urlString in urls {
                group.addTask {
                    do {
                        _ = try await self.loadImage(from: urlString)
                    } catch {
                        print("❌ [ImageCache] Failed to prefetch \(urlString): \(error)")
                    }
                }
            }
        }
        
        print("✅ [ImageCache] Prefetch complete")
    }
    
    /// Clear all cached images
    func clearCache() {
        cache.removeAllCachedResponses()
        print("🗑️ [ImageCache] Cache cleared")
    }
    
    /// Get cache statistics
    func getCacheStats() -> (memoryUsage: Int, diskUsage: Int) {
        let memoryUsage = cache.currentMemoryUsage
        let diskUsage = cache.currentDiskUsage
        
        print("📊 [ImageCache] Memory: \(memoryUsage / 1024 / 1024)MB / \(maxMemorySize / 1024 / 1024)MB")
        print("📊 [ImageCache] Disk: \(diskUsage / 1024 / 1024)MB / \(maxDiskSize / 1024 / 1024)MB")
        
        return (memoryUsage, diskUsage)
    }
}

enum ImageCacheError: Error, LocalizedError {
    case invalidURL
    case invalidImageData
    case networkError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid image URL"
        case .invalidImageData:
            return "Could not create image from data"
        case .networkError:
            return "Network error while downloading image"
        }
    }
}
