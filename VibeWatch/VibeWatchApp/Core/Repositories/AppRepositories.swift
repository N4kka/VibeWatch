import Foundation

/// Singleton container for the production Live repository implementations.
/// Inject these into ViewModels via init parameters (default = Live).
@MainActor
final class AppRepositories: ObservableObject {
    static let shared = AppRepositories()
    private init() {}

    let mediaDetail: any MediaDetailRepositoryProtocol = LiveMediaDetailRepository.shared
    let discovery: any DiscoveryRepositoryProtocol = LiveDiscoveryRepository.shared
    let lists: any ListRepositoryProtocol = LiveListRepository.shared
    let watchProviders: any WatchProvidersRepositoryProtocol = LiveWatchProvidersRepository.shared
}
