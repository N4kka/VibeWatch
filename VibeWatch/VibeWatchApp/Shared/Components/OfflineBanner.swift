import SwiftUI

/// Banner that appears when device is offline
struct OfflineBanner: View {
    @StateObject private var networkMonitor = NetworkMonitor.shared
    
    var body: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 14, weight: .medium))
                
                Text("You're offline. Showing cached content.")
                    .font(.system(size: 14, weight: .medium))
                
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.orange.opacity(0.9))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(), value: networkMonitor.isConnected)
        }
    }
}

#Preview {
    OfflineBanner()
}
