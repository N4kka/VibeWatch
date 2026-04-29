import SwiftUI

private struct ListRepositoryKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: any ListRepository {
        MainActor.assumeIsolated { DependencyContainer.shared.listRepository }
    }
}

private struct MediaRepositoryKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: any MediaRepository {
        MainActor.assumeIsolated { DependencyContainer.shared.mediaRepository }
    }
}

private struct DiscoveryRepositoryKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: any DiscoveryRepository {
        MainActor.assumeIsolated { DependencyContainer.shared.discoveryRepository }
    }
}

private struct NotificationRepositoryKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: any NotificationRepository {
        MainActor.assumeIsolated { DependencyContainer.shared.notificationRepository }
    }
}

extension EnvironmentValues {
    var listRepository: any ListRepository {
        get { self[ListRepositoryKey.self] }
        set { self[ListRepositoryKey.self] = newValue }
    }

    var mediaRepository: any MediaRepository {
        get { self[MediaRepositoryKey.self] }
        set { self[MediaRepositoryKey.self] = newValue }
    }

    var discoveryRepository: any DiscoveryRepository {
        get { self[DiscoveryRepositoryKey.self] }
        set { self[DiscoveryRepositoryKey.self] = newValue }
    }

    var notificationRepository: any NotificationRepository {
        get { self[NotificationRepositoryKey.self] }
        set { self[NotificationRepositoryKey.self] = newValue }
    }
}
