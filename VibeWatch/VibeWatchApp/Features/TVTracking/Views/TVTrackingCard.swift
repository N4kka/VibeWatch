import SwiftUI

/// Card episode-aware del tracking serie TV (stile JustWatch). Si arricchisce in modo lazy:
/// classifica/calcola da `seenKeys` + le stagioni della serie (caricate via cache), e carica
/// il titolo del prossimo episodio per la sola stagione che serve.
struct TVTrackingCard: View {
    let item: MediaListItem
    let bucket: TVTrackingFilter

    @ObservedObject private var seenManager = EpisodeSeenManager.shared

    @State private var show: TVShow?
    @State private var episodeTitle: String?
    @State private var seasonEpisodes: [Episode] = []   // stagione del prossimo episodio (per il mark)
    @State private var topProvider: Provider?
    @State private var providerLink: String?
    @State private var navigate = false

    // MARK: - Derivazioni (da show.seasons + seenKeys), tutte senza rete

    /// Coppie (stagione, episodio) di tutta la serie in ordine, speciali (stagione 0) esclusi.
    private var orderedPairs: [(season: Int, episode: Int)] {
        guard let seasons = show?.seasons else { return [] }
        var pairs: [(season: Int, episode: Int)] = []
        for s in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) where s.seasonNumber >= 1 && s.episodeCount > 0 {
            for e in 1...s.episodeCount { pairs.append((season: s.seasonNumber, episode: e)) }
        }
        return pairs
    }

    private func isSeen(_ season: Int, _ episode: Int) -> Bool {
        seenManager.seenShowIds.contains(item.mediaId) ||
        seenManager.seenKeys.contains("\(item.mediaId)_\(season)_\(episode)")
    }

    private var nextUnseen: (season: Int, episode: Int)? {
        orderedPairs.first { !isSeen($0.season, $0.episode) }
    }

    private var lastSeen: (season: Int, episode: Int)? {
        orderedPairs.last { isSeen($0.season, $0.episode) }
    }

    private var totalEpisodes: Int { orderedPairs.count }

    private var seenCount: Int {
        if seenManager.seenShowIds.contains(item.mediaId) { return totalEpisodes }
        return orderedPairs.filter { isSeen($0.season, $0.episode) }.count
    }

    private var seriesProgress: Double {
        if bucket == .upToDate { return 1 }
        guard totalEpisodes > 0 else { return 0 }
        return min(1, Double(seenCount) / Double(totalEpisodes))
    }

    /// Episodi rimanenti nella STAGIONE corrente (quella del prossimo episodio).
    private var seasonRemaining: Int {
        let targetSeason = (nextUnseen?.season) ?? (orderedPairs.first?.season ?? 1)
        let inSeason = orderedPairs.filter { $0.season == targetSeason }
        let seenInSeason = inSeason.filter { isSeen($0.season, $0.episode) }.count
        return max(0, inSeason.count - seenInSeason)
    }

    /// Etichetta SxEy del prossimo episodio (o S1E1 di default per "Da iniziare" pre-load).
    private var nextLabel: String {
        if let n = nextUnseen { return "S\(n.season) E\(n.episode)" }
        return bucket == .notStarted ? "S1 E1" : "—"
    }

    private var lastSeenLabel: String? {
        guard let l = lastSeen else { return nil }
        return "S\(l.season) E\(l.episode)"
    }

    private var showsSoonBadge: Bool { bucket == .upToDate && (show?.hasUpcomingEpisode ?? false) }

    /// Chiave del prossimo episodio: cambia quando avanzo (rilancia il caricamento del titolo).
    private var nextEpisodeKey: String {
        nextUnseen.map { "\($0.season)_\($0.episode)" } ?? "none"
    }

    var body: some View {
        ZStack { cardBody }
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .onTapGesture { navigate = true }
            .navigationDestination(isPresented: $navigate) {
                TVShowDetailView(tvShowId: item.mediaId)
            }
            .task(id: item.mediaId) { await loadShow() }
            .task(id: nextEpisodeKey) { await loadEpisodeTitleIfNeeded() }
            .task(id: item.mediaId) { await loadProviders() }
    }

    private var cardBody: some View {
        HStack(alignment: .top, spacing: 14) {
            poster
                .frame(width: 116, height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if bucket == .upToDate {
                            Text("N/A")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                        } else {
                            Text(nextLabel)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.theme.textPrimary)
                        }
                        Text(item.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                            .lineLimit(2)
                    }
                    Spacer()
                    trailingTopControls
                }

                if bucket == .upToDate {
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 4)
                    if let lastSeenLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.green)
                            Text(String(format: "tvTracking.lastSeen".localized, lastSeenLabel))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }
                } else {
                    if let episodeTitle, !episodeTitle.isEmpty {
                        Text(episodeTitle)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    watchNowButton
                }
            }
            .padding(.vertical, 2)
        }
        .padding(12)
    }

    @ViewBuilder
    private var trailingTopControls: some View {
        HStack(spacing: 8) {
            if showsSoonBadge {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                    Text("tvTracking.soon".localized)
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.green.opacity(0.85))
                .clipShape(Capsule())
            }
            Button { handleCheckmark() } label: {
                ZStack {
                    Circle()
                        .fill(bucket == .upToDate ? Color.green.opacity(0.25) : Color.white.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: bucket == .upToDate ? "checkmark.circle.fill" : "checkmark")
                        .font(.system(size: bucket == .upToDate ? 20 : 15, weight: .semibold))
                        .foregroundColor(bucket == .upToDate ? .green : .theme.textSecondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    @ViewBuilder
    private var poster: some View {
        ZStack(alignment: .bottom) {
            if let posterPath = item.posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)") {
                CachedAsyncImage(url: url, maxPixelSize: 500) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
                }
            } else {
                Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
                    .overlay { Image(systemName: "tv").foregroundColor(.theme.textSecondary) }
            }

            // Badge "N episodi rimanenti" (continua/da iniziare)
            if bucket != .upToDate, show != nil, seasonRemaining > 0 {
                Text(String(format: "tvTracking.episodesRemaining".localized, seasonRemaining))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.55))
                    .offset(y: -28)
            }

            // Barra di progresso (serie intera)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.25))
                    Rectangle().fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(seriesProgress))
                }
            }
            .frame(height: 5)
        }
    }

    @ViewBuilder
    private var watchNowButton: some View {
        if let provider = topProvider {
            Button {
                PlatformDeepLinkHelper.openPlatform(provider: provider, justWatchLink: providerLink, title: item.title)
            } label: {
                HStack(spacing: 8) {
                    CachedAsyncImage(url: provider.logoURL)
                        .frame(width: 20, height: 20)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("tvTracking.watchNow".localized)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Azioni

    private func handleCheckmark() {
        if bucket == .upToDate {
            unmarkLastEpisode()
        } else {
            markNextEpisode()
        }
    }

    private func markNextEpisode() {
        let target = nextUnseen ?? (orderedPairs.first) ?? (season: 1, episode: 1)
        EpisodeSeenManager.shared.markEpisodeSeen(showId: item.mediaId, seasonNumber: target.season, episodeNumber: target.episode)
    }

    /// "In pari" → torna a "Continua a guardare" smarcando l'ultimo episodio. Gestisce i tre
    /// modi in cui una serie è "in pari": chiavi episodio complete, flag whole-show, lista seen.
    private func unmarkLastEpisode() {
        let pairs = orderedPairs
        guard let last = pairs.last else { return }

        // 1) se è "vista" via lista seen, toglila dalla lista (altrimenti resta forzata in-pari).
        if let seenItem = ListManager.shared.seenList.items.first(where: { $0.mediaId == item.mediaId }) {
            Task { try? await ListManager.shared.removeFromList(listId: ListManager.shared.seenList.id, itemId: seenItem.id) }
        }
        // 2) materializza il flag whole-show in chiavi (tutte tranne l'ultimo episodio).
        if seenManager.seenShowIds.contains(item.mediaId) {
            EpisodeSeenManager.shared.expandWholeShowToEpisodes(
                showId: item.mediaId,
                allEpisodes: pairs.map { (season: $0.season, episode: $0.episode) }
            )
        } else {
            // assicura che tutto tranne l'ultimo risulti visto
            for p in pairs where !(p.season == last.season && p.episode == last.episode) {
                EpisodeSeenManager.shared.markEpisodeSeen(showId: item.mediaId, seasonNumber: p.season, episodeNumber: p.episode)
            }
        }
        EpisodeSeenManager.shared.unmarkEpisodeSeen(showId: item.mediaId, seasonNumber: last.season, episodeNumber: last.episode)
    }

    // MARK: - Caricamento lazy

    private func loadShow() async {
        // Servono le STAGIONI (per enumerare gli episodi) e next_episode_to_air: la cache locale
        // del detail le salva a nil, quindi prendo i dettagli completi da TMDB (cache propria del
        // service). Senza seasons non si calcola prossimo episodio/progresso/rimanenti.
        show = try? await TMDBService.shared.getTVShowDetails(id: item.mediaId)
    }

    private func loadEpisodeTitleIfNeeded() async {
        guard bucket != .upToDate, show != nil else { return }
        let target = nextUnseen ?? (orderedPairs.first) ?? (season: 1, episode: 1)
        if let cached = seasonEpisodes.first(where: { $0.seasonNumber == target.season && $0.episodeNumber == target.episode }) {
            episodeTitle = cached.name
            return
        }
        guard let detail = try? await TMDBService.shared.getTVSeasonDetails(showId: item.mediaId, seasonNumber: target.season) else { return }
        seasonEpisodes = detail.episodes
        episodeTitle = detail.episodes.first(where: { $0.episodeNumber == target.episode })?.name
    }

    private func loadProviders() async {
        let region = LocalizationManager.shared.currentCountry.id
        for await providers in LiveWatchProvidersRepository.shared.observeProviders(
            mediaId: item.mediaId, mediaType: .tv, region: region
        ) {
            if let providers {
                let result = ProviderSelection.selectTopProvider(from: providers)
                providerLink = result.link
                if let top = result.top { topProvider = top }
            }
        }
    }
}
