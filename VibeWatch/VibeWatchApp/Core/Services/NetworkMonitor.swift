import Foundation
import Network
import SwiftUI

/// Monitors network connectivity status
@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published var isConnected = true
    @Published var connectionType: ConnectionType = .unknown
    
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
                
                if self?.isConnected == true {
                    print("🌐 [NetworkMonitor] Connected (\(self?.connectionType.description ?? "unknown"))")
                } else {
                    print("📵 [NetworkMonitor] Disconnected")
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
    
    /// Check if currently on WiFi
    func isOnWiFi() async -> Bool {
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
