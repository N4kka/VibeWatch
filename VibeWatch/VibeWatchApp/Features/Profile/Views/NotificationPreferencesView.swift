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
        .navigationTitle("notifications.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if notificationService.notificationPermissionGranted {
                    Button("notifications.save".localized) {
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
        .onAppear {
            // Reload preferences when returning from child views to update counts
            if let loadedPrefs = notificationService.preferences {
                preferences = loadedPrefs
            }
        }
        .alert("notifications.settingsSaved".localized, isPresented: $showingSaveConfirmation) {
            Button("common.ok".localized) { }
        } message: {
            Text("notifications.preferencesUpdated".localized)
        }
    }

    // MARK: - Permission Status Section

    private var permissionStatusSection: some View {
        Section {
            if notificationService.notificationPermissionGranted {
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

                    Button(action: {
                        Task {
                            await requestPermissions()
                        }
                    }) {
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

    // MARK: - Notification Types Section

    private var notificationTypesSection: some View {
        Section {
            NotificationToggleRow(
                icon: "tv",
                title: "notifications.newEpisodes".localized,
                subtitle: "notifications.newEpisodesDesc".localized,
                isOn: $preferences.enableNewEpisodes
            )

            NotificationToggleRow(
                icon: "sparkles",
                title: "notifications.personalizedReleases".localized,
                subtitle: "notifications.personalizedReleasesDesc".localized,
                isOn: $preferences.enableReleaseAlerts
            )

            NotificationToggleRow(
                icon: "star.circle",
                title: "notifications.favoriteActors".localized,
                subtitle: "notifications.favoriteActorsDesc".localized,
                isOn: $preferences.enableActorAlerts
            )

            NotificationToggleRow(
                icon: "heart.circle",
                title: "notifications.similarContent".localized,
                subtitle: "notifications.similarContentDesc".localized,
                isOn: $preferences.enableSimilarContent
            )

            NotificationToggleRow(
                icon: "bookmark",
                title: "notifications.watchlistAlerts".localized,
                subtitle: "notifications.watchlistAlertsDesc".localized,
                isOn: $preferences.enableWatchlistAlerts
            )

            NotificationToggleRow(
                icon: "trophy",
                title: "notifications.milestones".localized,
                subtitle: "notifications.milestonesDesc".localized,
                isOn: $preferences.enableMilestones
            )
        } header: {
            Text("notifications.types".localized)
        } footer: {
            Text("notifications.typesFooter".localized)
                .font(.caption)
        }
    }

    // MARK: - Frequency Section

    private var frequencySection: some View {
        Section {
            Picker("notifications.dailyLimit".localized, selection: $preferences.maxDailyNotifications) {
                Text("1 \("notifications.perDay".localized)").tag(1)
                Text("2 \("notifications.perDay".localized)").tag(2)
                Text("3 \("notifications.perDay".localized)").tag(3)
                Text("5 \("notifications.perDay".localized)").tag(5)
                Text("notifications.unlimited".localized).tag(999)
            }
        } header: {
            Text("notifications.frequency".localized)
        } footer: {
            Text("notifications.frequencyFooter".localized)
                .font(.caption)
        }
    }

    // MARK: - Quiet Hours Section

    private var quietHoursSection: some View {
        Section {
            Picker("notifications.startTime".localized, selection: $preferences.quietHoursStart) {
                ForEach(0..<24) { hour in
                    Text(formatHour(hour)).tag(hour)
                }
            }

            Picker("notifications.endTime".localized, selection: $preferences.quietHoursEnd) {
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

    // MARK: - Pro Features Section

    private var proFeaturesSection: some View {
        Section {
            NavigationLink {
                CustomActorAlertsView(
                    selectedActorIds: $preferences.customActorAlerts,
                    userId: userId
                )
            } label: {
                HStack {
                    Image(systemName: "person.3")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("notifications.customActorAlerts".localized)
                            .font(.subheadline)
                        Text("\(preferences.customActorAlerts.count) \("misc.selected".localized)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            NavigationLink {
                CustomGenreAlertsView(
                    selectedGenreIds: $preferences.customGenreAlerts,
                    userId: userId
                )
            } label: {
                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("notifications.customGenreAlerts".localized)
                            .font(.subheadline)
                        Text("\(preferences.customGenreAlerts.count) \("misc.selected".localized)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("notifications.proFeatures".localized)
                Spacer()
                Image(systemName: "crown.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }
        } footer: {
            Text("notifications.proFeaturesDesc".localized)
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

        // Also save custom alerts to sync with backend (Pro feature)
        if !preferences.customActorAlerts.isEmpty {
            await notificationService.registerActorAlerts(userId: userId, actorIds: preferences.customActorAlerts)
        }
        if !preferences.customGenreAlerts.isEmpty {
            await notificationService.registerGenreAlerts(userId: userId, genreIds: preferences.customGenreAlerts)
        }

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
    let userId: String

    @State private var searchText = ""
    @State private var searchResults: [PersonSearchResult] = []
    @State private var topActors: [ActorPreference] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedActorNames: [Int: String] = [:] // Track names for selected actors

    private let tmdbService = TMDBService.shared
    private let notificationService = SmartNotificationService.shared

    var body: some View {
        List {
            // Search Results Section
            if !searchText.isEmpty {
                Section {
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding()
                            Spacer()
                        }
                    } else if searchResults.isEmpty {
                        Text("No actors found")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(searchResults) { actor in
                            ActorSearchRow(
                                actor: actor,
                                isSelected: selectedActorIds.contains(actor.id),
                                onTap: { toggleActor(actor) }
                            )
                        }
                    }
                } header: {
                    Text("Search Results")
                }
            }

            // Selected Actors Section
            if !selectedActorIds.isEmpty {
                Section {
                    ForEach(selectedActorIds, id: \.self) { actorId in
                        HStack {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.gray)
                                )

                            Text(selectedActorNames[actorId] ?? "Actor #\(actorId)")
                                .font(.subheadline)

                            Spacer()

                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            removeActor(actorId)
                        }
                    }
                } header: {
                    Text("Selected Actors (\(selectedActorIds.count))")
                }
            }

            // Suggestions from preferences (when not searching)
            if searchText.isEmpty && !topActors.isEmpty {
                Section {
                    ForEach(topActors) { actor in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(actor.name)
                                    .font(.subheadline)
                                Text("notifications.fromPreferences".localized)
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
                            toggleActorFromPreference(actor)
                        }
                    }
                } header: {
                    Text("notifications.favoriteActorsTitle".localized)
                } footer: {
                    Text("notifications.favoriteActorsFooter".localized)
                }
            }
        }
        .navigationTitle("notifications.customActorAlerts".localized)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search actors...")
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
        .task {
            await loadTopActors()
        }
    }

    private func toggleActor(_ actor: PersonSearchResult) {
        withAnimation {
            if let index = selectedActorIds.firstIndex(of: actor.id) {
                selectedActorIds.remove(at: index)
                selectedActorNames.removeValue(forKey: actor.id)
            } else {
                selectedActorIds.append(actor.id)
                selectedActorNames[actor.id] = actor.name
            }
        }
        // Save immediately when changed
        saveChanges()
    }

    private func toggleActorFromPreference(_ actor: ActorPreference) {
        withAnimation {
            if let index = selectedActorIds.firstIndex(of: actor.actorId) {
                selectedActorIds.remove(at: index)
                selectedActorNames.removeValue(forKey: actor.actorId)
            } else {
                selectedActorIds.append(actor.actorId)
                selectedActorNames[actor.actorId] = actor.name
            }
        }
        // Save immediately when changed
        saveChanges()
    }

    private func removeActor(_ actorId: Int) {
        withAnimation {
            selectedActorIds.removeAll { $0 == actorId }
            selectedActorNames.removeValue(forKey: actorId)
        }
        // Save immediately when changed
        saveChanges()
    }

    private func saveChanges() {
        Task {
            // Update the preferences in the service and save
            if var prefs = notificationService.preferences {
                prefs.customActorAlerts = selectedActorIds
                await notificationService.savePreferences(userId: userId, preferences: prefs)
                await notificationService.registerActorAlerts(userId: userId, actorIds: selectedActorIds)
                print("✅ [CustomActorAlerts] Saved \(selectedActorIds.count) actor alerts")
            }
        }
    }

    private func performSearch(query: String) {
        searchTask?.cancel()

        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            // Debounce: wait 300ms before searching
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard !Task.isCancelled else { return }

            do {
                let results = try await tmdbService.searchPerson(query: query)
                await MainActor.run {
                    self.searchResults = results
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.searchResults = []
                    self.isSearching = false
                }
            }
        }
    }

    private func loadTopActors() async {
        let profile = await UserPreferenceManager.shared.aggregatePreferences()
        topActors = Array(profile.topActors.prefix(20))
    }
}

// Actor Search Row Component
struct ActorSearchRow: View {
    let actor: PersonSearchResult
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Profile Image
            if let url = actor.profileURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.gray.opacity(0.3))
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.gray)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(actor.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Actor")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title3)
            } else {
                Image(systemName: "plus.circle")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Custom Genre Alerts View

struct CustomGenreAlertsView: View {
    @Binding var selectedGenreIds: [Int]
    let userId: String

    private let notificationService = SmartNotificationService.shared

    // All TMDB movie genres (static list - these IDs are stable)
    private let allGenres: [(id: Int, name: String)] = [
        (28, "Action"),
        (12, "Adventure"),
        (16, "Animation"),
        (35, "Comedy"),
        (80, "Crime"),
        (99, "Documentary"),
        (18, "Drama"),
        (10751, "Family"),
        (14, "Fantasy"),
        (36, "History"),
        (27, "Horror"),
        (10402, "Music"),
        (9648, "Mystery"),
        (10749, "Romance"),
        (878, "Science Fiction"),
        (10770, "TV Movie"),
        (53, "Thriller"),
        (10752, "War"),
        (37, "Western")
    ]

    var body: some View {
        List {
            // Selected genres at top
            if !selectedGenreIds.isEmpty {
                Section {
                    ForEach(selectedGenres, id: \.id) { genre in
                        GenreRow(
                            name: genre.name,
                            isSelected: true,
                            onTap: { toggleGenre(genre.id) }
                        )
                    }
                } header: {
                    Text("Selected Genres (\(selectedGenreIds.count))")
                }
            }

            // All genres
            Section {
                ForEach(allGenres, id: \.id) { genre in
                    GenreRow(
                        name: genre.name,
                        isSelected: selectedGenreIds.contains(genre.id),
                        onTap: { toggleGenre(genre.id) }
                    )
                }
            } header: {
                Text("All Genres")
            } footer: {
                Text("notifications.favoriteGenresFooter".localized)
            }
        }
        .navigationTitle("notifications.customGenreAlerts".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedGenres: [(id: Int, name: String)] {
        allGenres.filter { selectedGenreIds.contains($0.id) }
    }

    private func toggleGenre(_ genreId: Int) {
        withAnimation {
            if let index = selectedGenreIds.firstIndex(of: genreId) {
                selectedGenreIds.remove(at: index)
            } else {
                selectedGenreIds.append(genreId)
            }
        }
        // Save immediately when changed
        saveChanges()
    }

    private func saveChanges() {
        Task {
            // Update the preferences in the service and save
            if var prefs = notificationService.preferences {
                prefs.customGenreAlerts = selectedGenreIds
                await notificationService.savePreferences(userId: userId, preferences: prefs)
                await notificationService.registerGenreAlerts(userId: userId, genreIds: selectedGenreIds)
                print("✅ [CustomGenreAlerts] Saved \(selectedGenreIds.count) genre alerts")
            }
        }
    }
}

// Genre Row Component
struct GenreRow: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            Text(name)
                .font(.subheadline)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        NotificationPreferencesView(userId: "preview-user-123")
    }
}
