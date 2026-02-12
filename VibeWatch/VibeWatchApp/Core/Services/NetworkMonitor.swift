import Foundation
import Network
import SwiftUI

/// Monitors network connectivity status
@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true
    @Published var connectionType: ConnectionType = .unknown
    @Published private(set) var isInitialized = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vibewatch.networkmonitor")

    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown
    }

    private init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
                self?.connectionType = self?.getConnectionType(from: path) ?? .unknown
                self?.isInitialized = true

                if self?.isConnected == true {
                    Logger.debug("[NetworkMonitor] Connected (\(self?.connectionType.description ?? "unknown"))")
                } else {
                    Logger.debug("[NetworkMonitor] Disconnected")
                }
            }
        }

        monitor.start(queue: queue)
    }
    
    private func getConnectionType(from path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        }
        return .unknown
    }
    
    /// Check if currently on WiFi (waits for initialization if needed)
    func isOnWiFi() async -> Bool {
        // Wait for network status to be initialized (max 2 seconds)
        if !isInitialized {
            let startTime = Date()
            while !isInitialized && Date().timeIntervalSince(startTime) < 2.0 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            if !isInitialized {
                Logger.warning("[NetworkMonitor] Timeout waiting for network status, assuming WiFi")
                return true // Assume WiFi if we can't determine (better to prefetch than not)
            }
        }
        return connectionType == .wifi
    }
    
    deinit {
        monitor.cancel()
    }
}

extension NetworkMonitor.ConnectionType {
    var description: String {
        switch self {
        case .wifi: return "WiFi"
        case .cellular: return "Cellular"
        case .ethernet: return "Ethernet"
        case .unknown: return "Unknown"
        }
    }
}
