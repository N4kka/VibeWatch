import SwiftUI

/// SPEC v3 §9.3/§13.7 — le stats di base sul proprio profilo.
///
/// I numeri arrivano da `get_my_stats`, **mai** da una somma locale: in cache c'è un anno di
/// eventi (§5) e il totale lo conosce solo il server. Tre stati distinti, mai schiacciati:
/// caricamento, numeri (gli zeri sono numeri veri, non un errore), e **fallimento con riprova**
/// — un errore di rete non si traveste da "non hai visto niente".
@MainActor
final class ProfileStatsViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(UserStats)
        case failed
    }

    @Published private(set) var phase: Phase = .loading

    private let fetch: () async throws -> UserStats

    init(fetch: @escaping () async throws -> UserStats = { try await SupabaseService.shared.myStats() }) {
        self.fetch = fetch
    }

    func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            phase = .loaded(try await fetch())
        } catch {
            phase = .failed
        }
    }
}

struct ProfileStatsSection: View {
    @StateObject private var viewModel: ProfileStatsViewModel

    init() {
        _viewModel = StateObject(wrappedValue: ProfileStatsViewModel())
    }

    init(viewModel: ProfileStatsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("profile.stats.title".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            switch viewModel.phase {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 12)
            case .failed:
                VStack(spacing: 8) {
                    Text("profile.stats.loadFailed".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                    Button("common.retry".localized) {
                        Task { await viewModel.load() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            case .loaded(let stats):
                HStack(spacing: 0) {
                    statView(value: Self.timeFormatter.string(from: TimeInterval(stats.watchTimeSeconds)) ?? "0",
                             labelKey: "profile.stats.watchTime")
                    statView(value: "\(stats.moviesWatched)", labelKey: "profile.stats.movies")
                    statView(value: "\(stats.showsWatched)", labelKey: "profile.stats.shows")
                    statView(value: "\(stats.episodesWatched)", labelKey: "profile.stats.episodes")
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .task { await viewModel.load() }
    }

    private func statView(value: String, labelKey: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(labelKey.localized)
                .font(.system(size: 11))
                .foregroundColor(.theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
