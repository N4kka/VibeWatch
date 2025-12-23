import SwiftUI

/// User interface for managing smart notification preferences
/// Allows users to customize which notifications they receive and when
struct NotificationPreferencesView: View {
    @StateObject private var notificationService = SmartNotificationService.shared
    @StateObject private var quotaService = ClipQuotaService.shared
    @State private var preferences: NotificationPreferences
    @State private var isLoading = false
    @State private var showingSaveConfirmation = false
    @State private var permissionDenied = false

    private let userId: String

    init(userId: String) {
        self.userId = userId
        // Initialize with default preferences
        self._preferences = State(initialValue: NotificationPreferences())
    }

    var body: some View {
        Form {
            // Permission Status Section
            permissionStatusSection

            // Notification Types Section
            if notificationService.notificationPermissionGranted {
                notificationTypesSection
                frequencySection
                quietHoursSection

                // Pro features
                if isProUser {
                    proFeaturesSection
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if notificationService.notificationPermissionGranted {
                    Button("Save") {
                        Task {
                            await savePreferences()
                        }
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task {
            await loadPreferences()
        }
        .alert("Settings Saved", isPresented: $showingSaveConfirmation) {
            Button("OK") { }
        } message: {
            Text("Your notification preferences have been updated.")
        }
    }

    // MARK: - Permission Status Section

    private var permissionStatusSection: some View {
        Section {
            if notificationService.notificationPermissionGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Notifications Enabled")
                        .font(.subheadline)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.orange)
                        Text("Notifications Disabled")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    Text("Enable notifications to get personalized alerts about new episodes, releases, and content you'll love.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            await requestPermissions()
                        }
                    }) {
                        HStack {
                            Image(systemName: "bell.badge")
                            Text("Enable Notifications")
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
            Text("Status")
        }
    }

    // MARK: - Notification Types Section

    private var notificationTypesSection: some View {
        Section {
            NotificationToggleRow(
                icon: "tv",
                title: "New Episodes",
                subtitle: "Get notified when new episodes of shows you're watching are available",
                isOn: $preferences.enableNewEpisodes
            )

            NotificationToggleRow(
                icon: "sparkles",
                title: "Personalized Releases",
                subtitle: "New movies and shows matching your taste",
                isOn: $preferences.enableReleaseAlerts
            )

            NotificationToggleRow(
                icon: "star.circle",
                title: "Favorite Actors & Directors",
                subtitle: "New content from people you love",
                isOn: $preferences.enableActorAlerts
            )

            NotificationToggleRow(
                icon: "heart.circle",
                title: "Similar Content",
                subtitle: "Recommendations based on what you loved",
                isOn: $preferences.enableSimilarContent
            )

            NotificationToggleRow(
                icon: "bookmark",
                title: "Watchlist Alerts",
                subtitle: "When items on your watchlist become available",
                isOn: $preferences.enableWatchlistAlerts
            )

            NotificationToggleRow(
                icon: "trophy",
                title: "Milestones & Achievements",
                subtitle: "Celebrate your watching streaks and achievements",
                isOn: $preferences.enableMilestones
            )
        } header: {
            Text("Notification Types")
        } footer: {
            Text("Choose which notifications you'd like to receive")
                .font(.caption)
        }
    }

    // MARK: - Frequency Section

    private var frequencySection: some View {
        Section {
            Picker("Daily Limit", selection: $preferences.maxDailyNotifications) {
                Text("1 per day").tag(1)
                Text("2 per day").tag(2)
                Text("3 per day").tag(3)
                Text("5 per day").tag(5)
                Text("Unlimited").tag(999)
            }
        } header: {
            Text("Frequency")
        } footer: {
            Text("Maximum number of notifications you'll receive per day")
                .font(.caption)
        }
    }

    // MARK: - Quiet Hours Section

    private var quietHoursSection: some View {
        Section {
            Picker("Start Time", selection: $preferences.quietHoursStart) {
                ForEach(0..<24) { hour in
                    Text(formatHour(hour)).tag(hour)
                }
            }

            Picker("End Time", selection: $preferences.quietHoursEnd) {
                ForEach(0..<24) { hour in
                    Text(formatHour(hour)).tag(hour)
                }
            }
        } header: {
            Text("Quiet Hours")
        } footer: {
            Text("No notifications will be sent during these hours")
                .font(.caption)
        }
    }

    // MARK: - Pro Features Section

    private var proFeaturesSection: some View {
        Section {
            NavigationLink {
                CustomActorAlertsView(
                    selectedActorIds: $preferences.customActorAlerts
                )
            } label: {
                HStack {
                    Image(systemName: "person.3")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("Custom Actor Alerts")
                            .font(.subheadline)
                        Text("\(preferences.customActorAlerts.count) selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            NavigationLink {
                CustomGenreAlertsView(
                    selectedGenreIds: $preferences.customGenreAlerts
                )
            } label: {
                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("Custom Genre Alerts")
                            .font(.subheadline)
                        Text("\(preferences.customGenreAlerts.count) selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Pro Features")
                Spacer()
                Image(systemName: "crown.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }
        } footer: {
            Text("Get alerts for specific actors and genres you choose")
                .font(.caption)
        }
    }

    // MARK: - Helper Methods

    private func loadPreferences() async {
        isLoading = true

        await notificationService.checkPermissionStatus()
        await notificationService.loadPreferences(userId: userId)

        if let loadedPrefs = notificationService.preferences {
            preferences = loadedPrefs
        }

        isLoading = false
    }

    private func savePreferences() async {
        isLoading = true
        await notificationService.savePreferences(userId: userId, preferences: preferences)
        showingSaveConfirmation = true
        isLoading = false
    }

    private func requestPermissions() async {
        let granted = await notificationService.requestPermissions()

        if granted {
            await loadPreferences()
        } else {
            permissionDenied = true
        }
    }

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return formatter.string(from: date)
    }

    private var isProUser: Bool {
        return quotaService.isProUser
    }
}

// MARK: - Notification Toggle Row Component

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

// MARK: - Custom Actor Alerts View

struct CustomActorAlertsView: View {
    @Binding var selectedActorIds: [Int]
    @State private var searchText = ""
    @State private var topActors: [ActorPreference] = []

    var body: some View {
        List {
            Section {
                ForEach(topActors) { actor in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(actor.name)
                                .font(.subheadline)
                            Text("From your preferences")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if selectedActorIds.contains(actor.actorId) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleActor(actor.actorId)
                    }
                }
            } header: {
                Text("Your Favorite Actors")
            } footer: {
                Text("Get notified when these actors have new content")
            }
        }
        .navigationTitle("Custom Actor Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search actors...")
        .task {
            await loadTopActors()
        }
    }

    private func toggleActor(_ actorId: Int) {
        if let index = selectedActorIds.firstIndex(of: actorId) {
            selectedActorIds.remove(at: index)
        } else {
            selectedActorIds.append(actorId)
        }
    }

    private func loadTopActors() async {
        // Load user's top actors from UserPreferenceManager
        let profile = await UserPreferenceManager.shared.aggregatePreferences()
        topActors = Array(profile.topActors.prefix(20))
    }
}

// MARK: - Custom Genre Alerts View

struct CustomGenreAlertsView: View {
    @Binding var selectedGenreIds: [Int]
    @State private var topGenres: [GenrePreference] = []

    var body: some View {
        List {
            Section {
                ForEach(topGenres) { genre in
                    HStack {
                        Text(genre.genreName)
                            .font(.subheadline)

                        Spacer()

                        if selectedGenreIds.contains(genre.genreId) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleGenre(genre.genreId)
                    }
                }
            } header: {
                Text("Your Favorite Genres")
            } footer: {
                Text("Get notified about new releases in these genres")
            }
        }
        .navigationTitle("Custom Genre Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTopGenres()
        }
    }

    private func toggleGenre(_ genreId: Int) {
        if let index = selectedGenreIds.firstIndex(of: genreId) {
            selectedGenreIds.remove(at: index)
        } else {
            selectedGenreIds.append(genreId)
        }
    }

    private func loadTopGenres() async {
        // Load user's top genres from UserPreferenceManager
        let profile = await UserPreferenceManager.shared.aggregatePreferences()
        topGenres = Array(profile.topGenres.prefix(20))
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        NotificationPreferencesView(userId: "preview-user-123")
    }
}
