import SwiftUI

struct ActorFilmographyRow: View {
    let credit: PersonCredit

    @State private var topProvider: Provider?
    @State private var providerLink: String?
    @State private var isLoadingProviders = false
    @State private var providerLookupCompleted = false
    @State private var showNotifyMeAlert = false
    @State private var runtime: Int?
    @State private var seasonCount: Int?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.theme.accentOrange.opacity(0.2))

            HStack(alignment: .top, spacing: 16) {
                posterView

                VStack(alignment: .leading, spacing: 8) {
                    Text(credit.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)

                    let parts = subtitleComponents
                    if !parts.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                                if index > 0 { Text("|") }
                                if part.isStar {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.yellow)
                                }
                                Text(part.text)
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                    }

                    if let character = credit.character, !character.isEmpty {
                        Text(character)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(1)
                    }

                    if let overview = credit.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }

                    Spacer()

                    providerButton
                }
            }
            .padding(12)
        }
        .frame(height: 204)
        .task { await loadProviders() }
        .task(id: "\(credit.mediaType.rawValue)-\(credit.id)") { await loadDisplayDetails() }
        .alert("lists.notifyMeTitle".localized, isPresented: $showNotifyMeAlert) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text(String(format: "lists.notifyMeMessage".localized, credit.title))
        }
    }

    @ViewBuilder
    private var posterView: some View {
        if let url = credit.posterURL342 {
            CachedAsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.theme.backgroundDark.opacity(0.5))
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Rectangle()
                .fill(Color.theme.backgroundDark.opacity(0.5))
                .frame(width: 120, height: 180)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 30))
                        .foregroundColor(.theme.textSecondary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct SubtitlePart {
        let text: String
        let isStar: Bool
    }

    private var subtitleComponents: [SubtitlePart] {
        var parts: [SubtitlePart] = []
        if credit.mediaType == .tv {
            // TV: N seasons | year | ★ rating  (matches ListsView pattern)
            if let s = seasonCount, s > 0 {
                parts.append(SubtitlePart(text: "\(s) \(s == 1 ? "season" : "seasons")", isStar: false))
            }
            if let year = credit.year {
                parts.append(SubtitlePart(text: year, isStar: false))
            }
            if let avg = credit.voteAverage, avg > 0 {
                parts.append(SubtitlePart(text: String(format: "%.1f", avg), isStar: true))
            }
        } else {
            // Movie: ★ rating | year | duration
            if let avg = credit.voteAverage, avg > 0 {
                parts.append(SubtitlePart(text: String(format: "%.1f", avg), isStar: true))
            }
            if let year = credit.year {
                parts.append(SubtitlePart(text: year, isStar: false))
            }
            if let r = runtime, r > 0 {
                parts.append(SubtitlePart(text: formatDuration(r), isStar: false))
            }
        }
        return parts
    }

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(minutes)m"
    }

    private func loadDisplayDetails() async {
        switch credit.mediaType {
        case .movie:
            for await detail in LocalMediaDetailRepository.shared.observeMovie(id: credit.id) {
                if let r = detail.movie.runtime, r > 0 { runtime = r; return }
            }
            if let movie = try? await TMDBService.shared.getMovieDetails(id: credit.id) {
                if let r = movie.runtime, r > 0 { runtime = r }
            }
        case .tv:
            for await detail in LocalMediaDetailRepository.shared.observeTVShow(id: credit.id) {
                if let s = detail.tvShow.numberOfSeasons, s > 0 { seasonCount = s; return }
            }
            if let tvShow = try? await TMDBService.shared.getTVShowDetails(id: credit.id) {
                if let s = tvShow.numberOfSeasons, s > 0 { seasonCount = s }
            }
        }
    }

    @ViewBuilder
    private var providerButton: some View {
        if isLoadingProviders || !providerLookupCompleted {
            HStack {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.theme.accentOrange)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let provider = topProvider {
            Button {
                PlatformDeepLinkHelper.openPlatform(
                    provider: provider,
                    justWatchLink: providerLink,
                    title: credit.title
                )
            } label: {
                HStack {
                    CachedAsyncImage(url: provider.logoURL)
                        .frame(width: 20, height: 20)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(String(format: "lists.watchOn".localized, provider.providerName.uppercased()))
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.theme.accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else {
            Button { showNotifyMeAlert = true } label: {
                HStack(spacing: 4) {
                    Text("lists.notifyMe".localized)
                        .font(.system(size: 12, weight: .bold))
                    Text("🔔")
                        .font(.system(size: 12))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.theme.accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func loadProviders() async {
        guard !isLoadingProviders else { return }
        providerLookupCompleted = false
        topProvider = nil
        providerLink = nil
        isLoadingProviders = true
        let region = LocalizationManager.shared.currentCountry.id
        for await providers in LiveWatchProvidersRepository.shared.observeProviders(
            mediaId: credit.id, mediaType: credit.mediaType, region: region
        ) {
            if let providers { processProviders(providers) }
        }
        isLoadingProviders = false
        providerLookupCompleted = true
    }

    private func isValid(_ provider: Provider) -> Bool {
        guard provider.hasUsableLogo else { return false }
        if provider.externalLink != nil || providerLink != nil { return true }
        return PlatformDeepLinkHelper.hasPlatformHomepage(for: provider)
    }

    private func processProviders(_ countryProviders: CountryProviders) {
        providerLink = countryProviders.link
        if let flatrate = countryProviders.flatrate, let valid = flatrate.first(where: isValid) {
            topProvider = valid
        } else if let rent = countryProviders.rent, let valid = rent.first(where: isValid) {
            topProvider = valid
        } else if let buy = countryProviders.buy, let valid = buy.first(where: isValid) {
            topProvider = valid
        }
    }
}
