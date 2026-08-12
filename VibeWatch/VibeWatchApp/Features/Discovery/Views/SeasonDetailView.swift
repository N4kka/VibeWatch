import SwiftUI

struct SeasonDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: SeasonDetailViewModel
    @StateObject private var episodeSeenManager = EpisodeSeenManager.shared
    @StateObject private var listManager = ListManager.shared

    let showId: Int
    let showName: String
    let showBackdropPath: String?
    let showPosterPath: String?
    let tvShow: TVShow?
    let cast: [Cast]
    let director: Crew?

    @State private var showSavePanel = false
    @State private var selectedActor: Cast?
    /// I due popup del tap "visto": conferma per un episodio non ancora uscito, e il
    /// "hai visto anche i precedenti?" alla TV Time. Un solo stato: non possono coesistere.
    @State private var markPrompt: EpisodeMarkPrompt?
    @State private var actionError: String?
    /// Quanto si è scrollato: lo legge la barra fissa per decidere quando comparire.
    @State private var scrollOffset: CGFloat = 0

    private static let scrollSpace = "seasonDetailScroll"

    private enum EpisodeMarkPrompt {
        case unaired(Episode)
        case markPrevious(tapped: Episode, previous: [Episode])
        /// Il bottone "S* vista" su una stagione con episodi non ancora usciti: `unseen` è tutto
        /// ciò che verrebbe marcato, `aired` il sottoinsieme già andato in onda.
        case unairedSeason(unseen: [Episode], aired: [Episode])
    }

    init(showId: Int, seasonNumber: Int, showName: String, showBackdropPath: String?, showPosterPath: String? = nil, tvShow: TVShow? = nil, cast: [Cast] = [], director: Crew? = nil) {
        _viewModel = StateObject(wrappedValue: SeasonDetailViewModel(showId: showId, seasonNumber: seasonNumber))
        self.showId = showId
        self.showName = showName
        self.showBackdropPath = showBackdropPath
        self.showPosterPath = showPosterPath
        self.tvShow = tvShow
        self.cast = cast
        self.director = director
    }

    private var heroURL: URL? {
        if let path = viewModel.season?.posterPath {
            return URL(string: "https://image.tmdb.org/t/p/w780\(path)")
        }
        if let path = showBackdropPath {
            return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
        }
        return nil
    }

    private var seasonNumber: Int {
        viewModel.season?.seasonNumber ?? 0
    }

    private var isInWatchlist: Bool {
        listManager.isInList(listId: listManager.watchlist.id, mediaId: showId, mediaType: .tv)
    }

    private var isSeasonSeen: Bool {
        guard let episodes = viewModel.season?.episodes else { return false }
        return episodes.allSatisfy { isEpisodeSeen($0) }
    }

    /// Visto = tap locale (EpisodeSeenManager) OPPURE watch_event nello specchio locale
    /// (tap dal Tracking, import TV Time, altri device). Le due sorgenti restano separate
    /// perché hanno vite diverse; la lista le somma.
    private func isEpisodeSeen(_ episode: Episode) -> Bool {
        episodeSeenManager.isEpisodeSeen(
            showId: showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        ) || viewModel.watchedEpisodeNumbers.contains(episode.episodeNumber)
    }

    private func showMovie() -> Movie {
        Movie(
            id: showId,
            title: showName,
            overview: "",
            posterPath: showPosterPath,
            backdropPath: showBackdropPath,
            releaseDate: nil,
            voteAverage: 0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()

            if viewModel.isLoading && viewModel.season == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error, viewModel.season == nil {
                errorView(error)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            SeasonDetailHeaderView(heroURL: heroURL)

                            VStack(spacing: 24) {
                                if let season = viewModel.season {
                                    seasonInfoSection(season: season)
                                    seasonActionsSection(season: season)
                                    episodesSection(episodes: season.episodes)
                                    seasonDetailsInfoSection(season: season)
                                }
                            }
                            .padding(.horizontal, DetailLayout.seasonContentHorizontalInset)
                            .padding(.bottom, 40)
                        }
                        .frame(width: geometry.size.width)
                        .measuringDetailScrollOffset(in: Self.scrollSpace)
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .onPreferenceChange(DetailScrollOffsetKey.self) { raw in
                        let stepped = DetailScrollOffsetKey.quantized(raw)
                        if stepped != scrollOffset { scrollOffset = stepped }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            // Fuori dalla ScrollView: il back button resta a portata anche in fondo alla lista
            // episodi, che è lunga quanto la stagione.
            StickyDetailNavBar(
                title: viewModel.season.map { "\(showName) – \($0.name)" } ?? showName,
                scrollOffset: scrollOffset,
                showsTitleAlways: true,
                onBack: { dismiss() }
            )
        }
        .navigationBarHidden(true)
        .swipeBackGesture { dismiss() }
        .task { await viewModel.loadSeasonDetails() }
        // Un "visto" tappato sulle card del Tracking arriva nello specchio locale via pull:
        // quando il sync lo annuncia, la lista episodi si riallinea da sola.
        .onReceive(NotificationCenter.default.publisher(for: .syncEngineCompleted)) { _ in
            Task { await viewModel.refreshWatchedEvents() }
        }
        // Conferma per un episodio con data futura (o senza data): può capitare di vederlo in
        // anticipo per vie traverse, ma un tap involontario non deve sporcare il diario.
        .alert(
            "season.confirmUnaired.title".localized,
            isPresented: promptBinding(matching: { if case .unaired = $0 { return true } else { return false } }),
            presenting: unairedPromptEpisode
        ) { episode in
            Button("season.confirmUnaired.confirm".localized) {
                if let episodes = viewModel.season?.episodes {
                    askPreviousOrMark(episode, in: episodes, delayed: true)
                }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: { episode in
            Text(String(
                format: "season.confirmUnaired.message".localized,
                episode.seasonNumber, episode.episodeNumber))
        }
        // "S* vista" su una stagione con episodi non ancora usciti: si conferma prima di
        // marcare il futuro; "solo quelli usciti" compare quando c'è qualcosa di uscito.
        .alert(
            "season.confirmUnaired.title".localized,
            isPresented: promptBinding(matching: { if case .unairedSeason = $0 { return true } else { return false } }),
            presenting: unairedSeasonPayload
        ) { payload in
            Button("season.confirmUnairedSeason.markAll".localized) {
                mark(payload.unseen)
            }
            if !payload.aired.isEmpty {
                Button("season.confirmUnairedSeason.onlyAired".localized) {
                    mark(payload.aired)
                }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: { payload in
            Text(String(
                format: "season.confirmUnairedSeason.message".localized,
                payload.unseen.count - payload.aired.count))
        }
        // "Hai visto anche i precedenti?" alla TV Time: include i non visti prima del tappato.
        .alert(
            "season.confirmPrevious.title".localized,
            isPresented: promptBinding(matching: { if case .markPrevious = $0 { return true } else { return false } }),
            presenting: previousPromptPayload
        ) { payload in
            Button("season.confirmPrevious.markAll".localized) {
                mark(payload.previous + [payload.tapped])
            }
            Button("season.confirmPrevious.onlyThis".localized) {
                mark([payload.tapped])
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: { payload in
            Text(String(format: "season.confirmPrevious.message".localized, payload.previous.count))
        }
        .alert(
            "tracking.error.title".localized,
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("common.ok".localized) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: $showSavePanel) {
            SaveToListPanel(movie: showMovie(), mediaType: .tv)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.theme.background)
        }
        .navigationDestination(item: $selectedActor) { actor in
            ActorDetailView(
                actorId: actor.id,
                initialName: actor.name,
                initialProfileURL: actor.profileURL,
                previousTitle: showName
            )
        }
    }

    // MARK: - Sections

    private func seasonInfoSection(season: SeasonDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Text("\(season.episodeCount) episodes")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)

                if let year = season.year {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 3))
                        .foregroundColor(Color.white.opacity(0.4))
                        .padding(.horizontal, 6)
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 10)

                HStack(spacing: 4) {
                    Text("\(Int(season.voteAverage * 10))%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(showName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(season.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
            }

            if !season.overview.isEmpty {
                Text(season.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func seasonDetailsInfoSection(season: SeasonDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("movieDetail.information".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)

                VStack(alignment: .leading, spacing: 12) {
                    if Int(season.voteAverage * 10) > 0 {
                        InfoRow(title: "movieDetail.rating".localized, value: "\(Int(season.voteAverage * 10))%")
                    }

                    if let genres = tvShow?.genres, !genres.isEmpty {
                        InfoRow(title: "movieDetail.genres".localized, value: genres.map { $0.name }.joined(separator: ", "))
                    }

                    if let runtime = tvShow?.formattedEpisodeRuntime {
                        InfoRow(title: "movieDetail.runtime".localized, value: runtime)
                    }

                    if let country = tvShow?.productionCountries?.first,
                       let name = MediaInfoFormatting.localizedCountry(iso: country.iso, fallback: country.name) {
                        InfoRow(title: "movieDetail.country".localized, value: name)
                    }

                    if let director = director {
                        InfoRow(title: "movieDetail.director".localized, value: director.name)
                    }
                }
            }
            .padding(.horizontal, 20)

            if !cast.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("movieDetail.cast".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cast) { actor in
                                CastMemberCard(actor: actor) {
                                    selectedActor = actor
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    private func seasonActionsSection(season: SeasonDetail) -> some View {
        HStack(spacing: 12) {
            ActionButton(
                icon: "bookmark.fill",
                title: "movieDetail.save".localized,
                isActive: isInWatchlist
            ) {
                showSavePanel = true
            }

            ActionButton(
                icon: "checkmark.circle.fill",
                title: "S\(season.seasonNumber) \("tvDetail.seasonSeenShort".localized)",
                isActive: isSeasonSeen
            ) {
                withAnimation {
                    toggleSeasonSeen(episodes: season.episodes, seasonNumber: season.seasonNumber)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func episodesSection(episodes: [Episode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("tvDetail.episodesTitle".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                ForEach(episodes) { episode in
                    EpisodeRow(
                        episode: episode,
                        isSeen: isEpisodeSeen(episode),
                        onToggleSeen: { handleEpisodeTap(episode, in: episodes) }
                    )
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Prompt plumbing

    /// Una binding "questo caso di `markPrompt` è a schermo": il set(false) alla chiusura
    /// dell'alert azzera lo stato, come vuole `.alert(isPresented:presenting:)`.
    private func promptBinding(matching: @escaping (EpisodeMarkPrompt) -> Bool) -> Binding<Bool> {
        Binding(
            get: { markPrompt.map(matching) ?? false },
            set: { if !$0 { markPrompt = nil } }
        )
    }

    private var unairedPromptEpisode: Episode? {
        if case .unaired(let episode) = markPrompt { return episode }
        return nil
    }

    private var previousPromptPayload: (tapped: Episode, previous: [Episode])? {
        if case .markPrevious(let tapped, let previous) = markPrompt {
            return (tapped, previous)
        }
        return nil
    }

    private var unairedSeasonPayload: (unseen: [Episode], aired: [Episode])? {
        if case .unairedSeason(let unseen, let aired) = markPrompt {
            return (unseen, aired)
        }
        return nil
    }

    // MARK: - Actions

    /// Il tap sul check di un episodio. Lo smarcamento parte subito; la marcatura passa dai
    /// popup quando serve: prima la conferma per un episodio non ancora uscito, poi — se ci
    /// sono precedenti non visti — il "hai visto anche i precedenti?".
    private func handleEpisodeTap(_ episode: Episode, in episodes: [Episode]) {
        if isEpisodeSeen(episode) {
            unmark([episode], in: episodes)
        } else if isUnaired(episode) {
            markPrompt = .unaired(episode)
        } else {
            askPreviousOrMark(episode, in: episodes, delayed: false)
        }
    }

    /// Se prima dell'episodio tappato ci sono episodi non visti propone di includerli, altrimenti
    /// marca solo lui. `delayed` serve quando si arriva qui dal popup "non ancora uscito": il
    /// nuovo alert deve aspettare che SwiftUI abbia finito di chiudere il precedente, o il
    /// `set(false)` della binding lo azzera prima che compaia.
    private func askPreviousOrMark(_ episode: Episode, in episodes: [Episode], delayed: Bool) {
        let previous = episodes.filter {
            $0.episodeNumber < episode.episodeNumber && !isEpisodeSeen($0)
        }
        guard !previous.isEmpty else {
            mark([episode])
            return
        }
        if delayed {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                markPrompt = .markPrevious(tapped: episode, previous: previous)
            }
        } else {
            markPrompt = .markPrevious(tapped: episode, previous: previous)
        }
    }

    /// Non uscito = senza data o con data futura. La data di TMDB è un giorno di calendario:
    /// un episodio che esce oggi è "uscito", quindi il confronto è fra mezzenotti.
    private func isUnaired(_ episode: Episode) -> Bool {
        guard let airDate = episode.airDate, !airDate.isEmpty else { return true }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: airDate) else { return true }
        return date > Calendar.current.startOfDay(for: Date())
    }

    private func mark(_ episodes: [Episode]) {
        Task {
            do {
                try await TrackingActions.shared.markEpisodesWatched(
                    showId: showId,
                    episodes: episodes.map { ($0.seasonNumber, $0.episodeNumber) }
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func unmark(_ episodes: [Episode], in allEpisodes: [Episode]) {
        Task {
            do {
                try await TrackingActions.shared.unmarkEpisodesWatched(
                    showId: showId,
                    episodes: episodes.map { ($0.seasonNumber, $0.episodeNumber) },
                    allEpisodeNumbersInSeason: allEpisodes.map(\.episodeNumber)
                )
                await viewModel.refreshWatchedEvents()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Il bottone "S* vista": stesso canale dei singoli episodi (watch_events + pull), così anche
    /// da qui le card di Scopri e del Tracking si aggiornano — prima toccava solo lo stato locale.
    /// Se la stagione contiene episodi non ancora usciti (una stagione futura intera, o la coda
    /// di una in corso) si chiede prima, come per il tap sul singolo episodio.
    private func toggleSeasonSeen(episodes: [Episode], seasonNumber: Int) {
        if isSeasonSeen {
            unmark(episodes, in: episodes)
            return
        }
        let unseen = episodes.filter { !isEpisodeSeen($0) }
        let aired = unseen.filter { !isUnaired($0) }
        if aired.count == unseen.count {
            mark(unseen)
        } else {
            markPrompt = .unairedSeason(unseen: unseen, aired: aired)
        }
    }

    // MARK: - Error

    private func errorView(_ error: AppError) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(error.errorDescription ?? "Oops!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Button {
                Task { await viewModel.loadSeasonDetails() }
            } label: {
                Text("common.tryAgain".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(Color.orange)
                    .cornerRadius(25)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

/// Solo l'immagine: back button e titolo stanno nella `StickyDetailNavBar` della schermata, che
/// non scorre con il contenuto.
struct SeasonDetailHeaderView: View {
    let heroURL: URL?

    var body: some View {
        CachedAsyncImage(url: heroURL)
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: 300)
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.clear, Color.theme.background.opacity(0.8), Color.theme.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: Episode
    let isSeen: Bool
    let onToggleSeen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncImage(url: episode.stillURL, maxPixelSize: 600)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(Color.theme.cardBackground.clipShape(RoundedRectangle(cornerRadius: 8)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("S\(episode.seasonNumber)E\(episode.episodeNumber) - \(episode.name)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let date = episode.airDateFormatted {
                            Text(date)
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                        }

                        if let runtime = episode.formattedRuntime {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                            Text(runtime)
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }

                    if episode.voteAverage > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.theme.accentOrange)
                            Text(String(format: "%.1f", episode.voteAverage))
                                .font(.system(size: 12))
                                .foregroundColor(.theme.accentOrange)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(action: onToggleSeen) {
                    ZStack {
                        Circle()
                            .fill(isSeen ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: isSeen ? "checkmark.circle.fill" : "checkmark")
                            .font(.system(size: isSeen ? 20 : 16, weight: .semibold))
                            .foregroundColor(isSeen ? .green : .theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if !episode.overview.isEmpty {
                Text(episode.overview)
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(3)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
