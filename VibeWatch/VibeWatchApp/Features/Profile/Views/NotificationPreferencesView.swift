import SwiftUI

struct NotificationPreferencesView: View {
    @StateObject private var notificationService = NotificationService.shared
    @State private var preferences: NotificationPreferences = Self.loadFromDefaults()
    @State private var isSyncing = false

    private let userId: String

    init(userId: String) {
        self.userId = userId
    }

    var body: some View {
        Form {
            permissionStatusSection

            if notificationService.notificationsEnabled {
                notificationTypesSection
                quietHoursSection
            }
        }
        .navigationTitle("notifications.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notificationService.refreshAuthorizationStatus()
        }
    }

    // MARK: - Sections

    private var permissionStatusSection: some View {
        Section {
            if notificationService.notificationsEnabled {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("notifications.enabled".localized)
                        .font(.subheadline)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.orange)
                        Text("notifications.disabled".localized)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    Text("notifications.enableDescription".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        Task { _ = await notificationService.enableNotifications() }
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge")
                            Text("notifications.enableButton".localized)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("notifications.status".localized)
        }
    }

    private var notificationTypesSection: some View {
        Section {
            NotificationToggleRow(
                icon: "play.square.stack",
                title: "notifications.newAvailability".localized,
                subtitle: "notifications.newAvailabilityDesc".localized,
                isOn: binding(for: \.enableNewAvailability)
            )

            NotificationToggleRow(
                icon: "sparkles",
                title: "notifications.newRelease".localized,
                subtitle: "notifications.newReleaseDesc".localized,
                isOn: binding(for: \.enableNewRelease)
            )

            NotificationToggleRow(
                icon: "tv",
                title: "notifications.episodeAired".localized,
                subtitle: "notifications.episodeAiredDesc".localized,
                isOn: binding(for: \.enableEpisodeAired)
            )

            NotificationToggleRow(
                icon: "arrow.counterclockwise.circle",
                title: "notifications.continueWatching".localized,
                subtitle: "notifications.continueWatchingDesc".localized,
                isOn: binding(for: \.enableContinueWatching)
            )

            NotificationToggleRow(
                icon: "trophy",
                title: "notifications.listMilestone".localized,
                subtitle: "notifications.listMilestoneDesc".localized,
                isOn: binding(for: \.enableListMilestone)
            )
        } header: {
            Text("notifications.types".localized)
        } footer: {
            Text("notifications.typesFooter".localized)
                .font(.caption)
        }
    }

    private var quietHoursSection: some View {
        Section {
            Picker("notifications.startTime".localized, selection: Binding(
                get: { preferences.quietHoursStart },
                set: { preferences.quietHoursStart = $0; persist() }
            )) {
                ForEach(0..<24) { hour in
                    Text(formatHour(hour)).tag(hour)
                }
            }

            Picker("notifications.endTime".localized, selection: Binding(
                get: { preferences.quietHoursEnd },
                set: { preferences.quietHoursEnd = $0; persist() }
            )) {
                ForEach(0..<24) { hour in
                    Text(formatHour(hour)).tag(hour)
                }
            }
        } header: {
            Text("notifications.quietHours".localized)
        } footer: {
            Text("notifications.quietHoursDesc".localized)
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func binding(for keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0; persist() }
        )
    }

    private func persist() {
        Self.saveToDefaults(preferences)
        Task {
            await NotificationService.shared.syncPreferencesToSupabase(preferences)
        }
    }

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return formatter.string(from: date)
    }

    // MARK: - UserDefaults persistence

    private static let defaultsKey = "notificationPreferences_v2"

    static func loadFromDefaults() -> NotificationPreferences {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let prefs = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else { return NotificationPreferences() }
        return prefs
    }

    static func saveToDefaults(_ prefs: NotificationPreferences) {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Notification Toggle Row

struct NotificationToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        NotificationPreferencesView(userId: "preview-user-123")
    }
}
