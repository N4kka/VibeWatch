#if DEBUG
import SwiftUI

struct AnalyticsHealthDebugView: View {
    @State private var events: [AnalyticsService.EventSnapshot] = []
    @State private var diagnostics: AnalyticsService.Diagnostics?
    @State private var lastFlushStatus: String?

    var body: some View {
        List {
            Section("PostHog") {
                if let diagnostics {
                    row(label: "Configured", value: diagnostics.isConfigured ? "yes" : "NO — events dropped")
                    row(label: "Enabled (opt-in)", value: diagnostics.isEnabled ? "yes" : "no")
                    row(label: "Distinct ID", value: diagnostics.distinctId ?? "—")
                    row(label: "Replay recording", value: diagnostics.isReplayActive ? "yes" : "no")
                } else {
                    Text("No diagnostics yet.")
                        .foregroundColor(.secondary)
                }

                if let lastFlushStatus {
                    row(label: "Last flush", value: lastFlushStatus)
                }

                Button("Flush Now") {
                    AnalyticsService.shared.flushNow()
                    lastFlushStatus = "Requested at \(Date().formatted(date: .omitted, time: .standard))"
                    refresh()
                }
            }

            Section("Recent Events") {
                if events.isEmpty {
                    Text("No events recorded.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.name)
                                .font(.headline)
                            Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let parameters = event.parameters, !parameters.isEmpty {
                                Text(format(parameters: parameters))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Analytics Health")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    refresh()
                }
            }
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        events = AnalyticsService.shared.recentEvents(limit: 50).reversed()
        diagnostics = AnalyticsService.shared.diagnostics()
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func format(parameters: [String: Any]) -> String {
        if JSONSerialization.isValidJSONObject(parameters),
           let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: parameters)
    }
}
#endif
