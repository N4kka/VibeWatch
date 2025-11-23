import SwiftUI

/// Debug view to monitor sync status and manage sync queue
struct SyncStatusView: View {
    @EnvironmentObject var syncWorker: SyncWorker
    @State private var pendingOps: [[String: Any]] = []
    @State private var showResetAlert = false
    
    var body: some View {
        List {
            // Status Section
            Section("Sync Status") {
                HStack {
                    Text("Connected")
                    Spacer()
                    Circle()
                        .fill(syncWorker.isOnline ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                }
                
                HStack {
                    Text("Syncing")
                    Spacer()
                    if syncWorker.isSyncing {
                        ProgressView()
                    } else {
                        Text("Idle")
                            .foregroundColor(.secondary)
                    }
                }
                
                if let lastSync = syncWorker.lastSyncDate {
                    HStack {
                        Text("Last Sync")
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let error = syncWorker.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Error")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            // Queue Stats
            Section("Queue Statistics") {
                HStack {
                    Text("Pending")
                    Spacer()
                    Text("\(syncWorker.pendingCount)")
                        .foregroundColor(syncWorker.pendingCount > 0 ? .orange : .green)
                        .fontWeight(.semibold)
                }
                
                HStack {
                    Text("Stuck")
                    Spacer()
                    Text("\(syncWorker.stuckCount)")
                        .foregroundColor(syncWorker.stuckCount > 0 ? .red : .green)
                        .fontWeight(.semibold)
                }
            }
            
            // Actions
            Section("Actions") {
                Button(action: {
                    Task {
                        await syncWorker.forceSyncNow()
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Force Sync Now")
                    }
                }
                .disabled(syncWorker.isSyncing || syncWorker.pendingCount == 0)
                
                Button(action: {
                    Task {
                        pendingOps = await syncWorker.getPendingOperations()
                    }
                }) {
                    HStack {
                        Image(systemName: "list.bullet")
                        Text("View Pending Operations")
                    }
                }
                
                if syncWorker.stuckCount > 0 {
                    Button(role: .destructive, action: {
                        showResetAlert = true
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reset Stuck Operations")
                        }
                    }
                }
            }
            
            // Pending Operations List
            if !pendingOps.isEmpty {
                Section("Pending Operations") {
                    ForEach(Array(pendingOps.enumerated()), id: \.offset) { index, op in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(op["operation_type"] as? String ?? "")
                                    .fontWeight(.semibold)
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text(op["table_name"] as? String ?? "")
                                    .foregroundColor(.secondary)
                            }
                            
                            if let attempts = op["attempts"] as? Int, attempts > 0 {
                                Text("Attempts: \(attempts)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            
                            if let error = op["last_error"] as? String, !error.isEmpty {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Sync Status")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset Stuck Operations?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await syncWorker.resetStuckOperations()
                }
            }
        } message: {
            Text("This will reset all stuck operations and retry them. Are you sure?")
        }
    }
}

#Preview {
    NavigationStack {
        SyncStatusView()
            .environmentObject(SyncWorker.shared)
    }
}
