#if DEBUG
import SwiftUI

struct AnalyticsHealthDebugView: View {
    @State private var events: [AnalyticsService.EventSnapshot] = []
    @State private var diagnostics: PostHogClient.Diagnostics?
    @State private var lastFlushStatus: String?
    @State private var isFlushing = false

    var body: some View {
        List {
            Section("PostHog") {
                if let diagnostics {
                    row(label: "Queue count", value: "\(diagnostics.queueCount)")
                    row(label: "Flushing", value: diagnostics.isFlushing ? "yes" : "no")
                    row(label: "Flush attempts", value: "\(diagnostics.flushAttemptCount)")
                    row(label: "Last error", value: diagnostics.lastFlushErrorDescription ?? "none")
                    row(label: "Last error at", value: diagnostics.lastFlushErrorAt?.description ?? "—")
                } else {
                    Text("No diagnostics yet.")
                        .foregroundColor(.secondary)
                }

                if let lastFlushStatus {
                    row(label: "Last flush", value: lastFlushStatus)
                }

                Button(isFlushing ? "Flushing..." : "Flush Now") {
                    Task { await flushNow() }
                }
                .disabled(isFlushing)
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
                    Task { await refresh() }
                }
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        await MainActor.run {
            events = AnalyticsService.shared.recentEvents(limit: 50).reversed()
        }
        diagnostics = await PostHogClient.shared.diagnostics()
    }

    private func flushNow() async {
        isFlushing = true
        defer { isFlushing = false }

        do {
            try await PostHogClient.shared.flush()
            lastFlushStatus = "Success"
        } catch {
            lastFlushStatus = "Failed: \(error)"
        }
        diagnostics = await PostHogClient.shared.diagnostics()
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
