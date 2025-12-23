import Foundation
import Combine

@MainActor
class ListAvailabilityService: ObservableObject {
    static let shared = ListAvailabilityService()
    
    @Published var availableItems: [String: Set<String>] = [:] // ItemID -> Set<PlatformName>
    private var processingItems: Set<String> = []
    
    private let tmdbService = TMDBService.shared
    
    func checkAvailability(for items: [MediaListItem], on platforms: Set<String>) async {
        let itemsToCheck = items.filter { item in
            // Check if we already have data for this item
            if availableItems[item.id] != nil { return false }
            return true
        }
        
        guard !itemsToCheck.isEmpty else { return }
        
        // Filter out items already being processed
        let newItems = itemsToCheck.filter { !processingItems.contains($0.id) }
        guard !newItems.isEmpty else { return }
        
        newItems.forEach { processingItems.insert($0.id) }
        
        await withTaskGroup(of: (String, Set<String>).self) { group in
            for item in newItems {
                group.addTask {
                    let providers = await self.fetchProviders(for: item)
                    return (item.id, providers)
                }
            }
            
            for await (itemId, providers) in group {
                self.availableItems[itemId] = providers
                self.processingItems.remove(itemId)
            }
        }
    }
    
    private func fetchProviders(for item: MediaListItem) async -> Set<String> {
        do {
            let providers: WatchProvider
            if item.mediaType == .movie {
                providers = try await tmdbService.getMovieWatchProviders(id: item.mediaId)
            } else {
                providers = try await tmdbService.getTVShowWatchProviders(id: item.mediaId)
            }
            
            let countryCode = LocalizationManager.shared.currentCountry.id
            guard let countryProviders = providers.results[countryCode] else { return [] }
            
            var available: Set<String> = []
            
            // Collect flatrate providers
            if let flatrate = countryProviders.flatrate {
                for provider in flatrate {
                    available.insert(provider.providerName)
                }
            }
            
            // We could also add rent/buy if we wanted, but "Streaming Platforms" usually implies subscription (flatrate).
            // Let's stick to flatrate for now as that's what "Streaming Platform" usually filters.
            
            return available
        } catch {
            print("❌ Failed to fetch providers for \(item.title): \(error)")
            return []
        }
    }
}
