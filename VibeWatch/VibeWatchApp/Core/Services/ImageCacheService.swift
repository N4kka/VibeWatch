import Foundation
import UIKit
import ImageIO

/// Service for caching images offline
/// Uses URLCache for automatic caching with size limits and invalidation
@MainActor
class ImageCacheService: ImageCacheServiceProtocol {
    static let shared = ImageCacheService()
    
    private let cache: URLCache
    private let session: URLSession
    
    // Cache configuration
    private let maxMemorySize = 100 * 1024 * 1024  // 100 MB in memory
    private let maxDiskSize = 500 * 1024 * 1024     // 500 MB on disk
    private let maxCacheAgeDays = 30                // 30 days before automatic cleanup
    
    // Cache size preferences
    enum CacheSizePreference: String, CaseIterable, Codable {
        case small = "Small (200MB)"
        case medium = "Medium (500MB)"
        case large = "Large (1GB)"
        
        var diskSize: Int {
            switch self {
            case .small: return 200 * 1024 * 1024
            case .medium: return 500 * 1024 * 1024
            case .large: return 1024 * 1024 * 1024
            }
        }
    }
    
    // Image prefetch preferences
    enum ImagePrefetchOption: String, CaseIterable, Codable {
        case always = "Always"
        case wifiOnly = "WiFi Only"
        case never = "Never"
    }
    
    private init() {
        // Load user's cache size preference from UserDefaults
        let preferredDiskSize: Int
        if let preferenceString = UserDefaults.standard.string(forKey: "imageCacheSizePreference"),
           let preference = CacheSizePreference(rawValue: preferenceString) {
            preferredDiskSize = preference.diskSize
            Logger.debug("[ImageCache] Using user preference: \(preference.rawValue)")
        } else {
            // Default to medium size
            preferredDiskSize = CacheSizePreference.medium.diskSize
            Logger.debug("[ImageCache] Using default size: Medium (500MB)")
        }
        
        // Configure URLCache with user's preferred size
        cache = URLCache(
            memoryCapacity: maxMemorySize,
            diskCapacity: preferredDiskSize,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ImageCache")
        )
        
        // Configure URLSession with cache
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        
        session = URLSession(configuration: config)
        
        Logger.debug("[ImageCache] Initialized with \(maxMemorySize / 1024 / 1024)MB memory, \(preferredDiskSize / 1024 / 1024)MB disk")
    }
    
    /// Load image from URL with caching.
    func loadImage(from urlString: String) async throws -> UIImage {
        try await loadImage(from: urlString, maxPixelSize: nil)
    }

    /// Load image from URL with caching e downsampling opzionale (Fase 3 §2.2).
    ///
    /// `maxPixelSize` (in PIXEL): se valorizzato, l'immagine viene ridimensionata a quella
    /// dimensione massima via ImageIO (`CGImageSourceCreateThumbnailAtIndex`) — così le griglie
    /// di poster non tengono in RAM bitmap full-res. La cache su disco/URLCache conserva sempre
    /// i Data originali, quindi la stessa immagine può essere ri-decodificata a dimensioni diverse.
    /// Il decode/downsampling avviene OFF-MAIN (Task.detached), non sul main actor.
    func loadImage(from urlString: String, maxPixelSize: CGFloat?) async throws -> UIImage {
        guard let url = URL(string: urlString) else {
            throw ImageCacheError.invalidURL
        }

        let request = URLRequest(url: url)

        // 1. Recupera i Data: da cache (URLCache) o rete.
        let data: Data
        let responseToStore: URLResponse?
        if let cachedResponse = cache.cachedResponse(for: request) {
            data = cachedResponse.data
            responseToStore = nil
            Logger.debug("[ImageCache] Loaded from cache: \(url.lastPathComponent)")
        } else {
            Logger.debug("[ImageCache] Downloading: \(url.lastPathComponent)")
            let (downloaded, response) = try await session.data(from: url)
            data = downloaded
            responseToStore = response
        }

        // 2. Decode/downsampling OFF-MAIN.
        let image = try await Self.decodeImage(data: data, maxPixelSize: maxPixelSize)

        // 3. Salva in cache i Data ORIGINALI (non il thumbnail) se appena scaricati.
        if let responseToStore {
            cache.storeCachedResponse(CachedURLResponse(response: responseToStore, data: data), for: request)
        }

        return image
    }

    /// Decodifica (ed eventualmente ridimensiona) i Data fuori dal main thread.
    nonisolated private static func decodeImage(data: Data, maxPixelSize: CGFloat?) async throws -> UIImage {
        try await Task.detached(priority: .utility) {
            if let maxPixelSize, maxPixelSize > 0,
               let downsampled = downsample(data: data, maxPixelSize: maxPixelSize) {
                return downsampled
            }
            guard let image = UIImage(data: data) else {
                throw ImageCacheError.invalidImageData
            }
            return image
        }.value
    }

    /// Downsampling via ImageIO: decodifica direttamente alla dimensione richiesta senza mai
    /// materializzare il bitmap full-res. `maxPixelSize` è la dimensione massima (lato lungo) in pixel.
    nonisolated static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,        // decode subito, qui (off-main)
            kCGImageSourceCreateThumbnailWithTransform: true,  // rispetta l'orientamento EXIF
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
    
    /// Prefetch images for offline viewing (WiFi only)
    func prefetchImages(_ urls: [String], onWiFiOnly: Bool = true) async {
        guard !urls.isEmpty else { return }
        
        // Check network type if WiFi-only
        if onWiFiOnly {
            let isOnWiFi = await NetworkMonitor.shared.isOnWiFi()
            guard isOnWiFi else {
                Logger.warning("[ImageCache] Skipping prefetch - not on WiFi")
                return
            }
        }
        
        Logger.debug("[ImageCache] Prefetching \(urls.count) images...")
        
        await withTaskGroup(of: Void.self) { group in
            for urlString in urls {
                group.addTask {
                    do {
                        _ = try await self.loadImage(from: urlString)
                    } catch {
                        Logger.error("[ImageCache] Failed to prefetch \(urlString): \(error)")
                    }
                }
            }
        }
        
        Logger.debug("[ImageCache] Prefetch complete")
    }
    
    /// Clear all cached images
    func clearCache() {
        cache.removeAllCachedResponses()
        Logger.debug("[ImageCache] Cache cleared")
    }
    
    /// Get cache statistics
    func getCacheStats() -> (memoryUsage: Int, diskUsage: Int) {
        let memoryUsage = cache.currentMemoryUsage
        let diskUsage = cache.currentDiskUsage
        
        Logger.debug("[ImageCache] Memory: \(memoryUsage / 1024 / 1024)MB / \(maxMemorySize / 1024 / 1024)MB")
        Logger.debug("[ImageCache] Disk: \(diskUsage / 1024 / 1024)MB / \(maxDiskSize / 1024 / 1024)MB")
        
        return (memoryUsage, diskUsage)
    }
    
    /// Clean up old cached images (older than maxCacheAgeDays)
    func cleanupOldCache() {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ImageCache")
        
        guard let directory = cacheDirectory, FileManager.default.fileExists(atPath: directory.path) else {
            Logger.debug("[ImageCache] No cache directory found")
            return
        }
        
        let fileManager = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxCacheAgeDays, to: Date()) ?? Date()
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
            
            var deletedCount = 0
            for fileURL in contents {
                let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                if let modificationDate = resourceValues.contentModificationDate, 
                   modificationDate < cutoffDate {
                    try fileManager.removeItem(at: fileURL)
                    deletedCount += 1
                }
            }
            
            Logger.debug("[ImageCache] Cleaned up \(deletedCount) old cache files")
        } catch {
            Logger.error("[ImageCache] Error cleaning cache: \(error)")
        }
    }
    
    /// Set cache size based on user preference
    func setCacheSizePreference(_ preference: CacheSizePreference) {
        // Store the new preference for future cache operations
        UserDefaults.standard.set(preference.rawValue, forKey: "imageCacheSizePreference")
        Logger.debug("[ImageCache] Cache size preference set to \(preference.rawValue)")
        Logger.debug("[ImageCache] New cache size will take effect on next app launch")

        // Note: URLCache doesn't allow changing disk capacity after initialization.
        // The new size will be applied when the app restarts and ImageCacheService is reinitialized.
    }

    /// Set image prefetch option
    func setImagePrefetchOption(_ option: ImagePrefetchOption) {
        UserDefaults.standard.set(option.rawValue, forKey: "imagePrefetchOption")
        Logger.debug("[ImageCache] Image prefetch option set to \(option.rawValue)")
    }

    /// Get current image prefetch option from UserDefaults
    func getCurrentImagePrefetchOption() -> ImagePrefetchOption {
        if let optionString = UserDefaults.standard.string(forKey: "imagePrefetchOption"),
           let option = ImagePrefetchOption(rawValue: optionString) {
            return option
        }
        return .wifiOnly // Default
    }
    
    /// Get current cache size preference from UserDefaults
    func getCurrentCacheSizePreference() -> CacheSizePreference {
        if let preferenceString = UserDefaults.standard.string(forKey: "imageCacheSizePreference"),
           let preference = CacheSizePreference(rawValue: preferenceString) {
            return preference
        }
        return .medium // Default
    }
    
    /// Check if image prefetching should proceed based on user preference and network
    func shouldPrefetchImages(preference: ImagePrefetchOption) async -> Bool {
        switch preference {
        case .always:
            return true
        case .wifiOnly:
            return await NetworkMonitor.shared.isOnWiFi()
        case .never:
            return false
        }
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
