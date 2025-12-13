import SwiftUI

/// Banner that appears when device is offline
struct OfflineBanner: View {
    @StateObject private var networkMonitor = NetworkMonitor.shared
    
    var body: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 14))
                
                Text("common.offline".localized)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.orange)
        }
    }
}

#Preview {
    OfflineBanner()
}
