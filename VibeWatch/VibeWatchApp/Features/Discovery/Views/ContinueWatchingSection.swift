import SwiftUI

/// Redesign 2.0 — "Continua a guardare" torna subito on top di Scopri.
///
/// Le card sono le serie del bucket `up_next` (calcolato dal server, letto dallo specchio
/// locale): un episodio pronto, il progresso, dove guardarlo, e il check per marcarlo visto
/// senza cambiare tab. Il link "Tracking" dichiara dove vive la lista completa.
struct ContinueWatchingSection: View {
    @ObservedObject var viewModel: DiscoveryTrackingHighlightsViewModel
    let onOpenShow: (Int) -> Void

    /// La serie con l'azione in volo: il progresso lo ricalcola il server (stessa ragione del
    /// Tracking) — senza stato visibile, chi non vede nulla tocca due volte.
    @State private var busyShowId: Int?
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Text("discovery.continueWatching".localized)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .navigateToTrackingTab, object: nil)
                } label: {
                    Text("tab.tracking".localized)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.continueWatching.prefix(10)) { row in
                        card(row)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .alert(
            "tracking.error.title".localized,
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("common.ok".localized) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func card(_ row: TrackingRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            poster(row)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.nextLabel ?? "tracking.caughtUp".localized)
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.theme.accentOrange)
                        Text(row.showName ?? "tracking.unknownShow".localized)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    checkButton(row)
                }

                if let name = row.nextEpisodeName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 11.5))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack {
                    WatchProviderPill(mediaId: row.showId, mediaType: .tv, title: row.showName ?? "")
                    Spacer(minLength: 6)
                    Text("\(row.watchedCount)/\(row.airedCount)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(width: 296, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture { onOpenShow(row.showId) }
    }

    private func poster(_ row: TrackingRow) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if let path = row.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w185\(path)") {
                    CachedAsyncImage(url: url, maxPixelSize: 200) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.white.opacity(0.1))
                    }
                } else {
                    Rectangle().fill(Color.white.opacity(0.1))
                        .overlay { Image(systemName: "tv").foregroundColor(.theme.textSecondary) }
                }
            }
            .frame(width: 62, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // La barra di progresso sta SUL poster, come nel prototipo: il poster è la card.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.22))
                    Rectangle()
                        .fill(Color.theme.accentOrange)
                        .frame(width: max(0, geo.size.width * row.progress))
                }
            }
            .frame(width: 62, height: 4)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        }
        .frame(width: 62, height: 92)
    }

    private func checkButton(_ row: TrackingRow) -> some View {
        Button {
            mark(row)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 32, height: 32)
                if busyShowId == row.showId {
                    ProgressView().scaleEffect(0.6).tint(.theme.textSecondary)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(busyShowId != nil)
    }

    private func mark(_ row: TrackingRow) {
        guard busyShowId == nil else { return }
        busyShowId = row.showId
        Task {
            defer { busyShowId = nil }
            do {
                try await TrackingActions.shared.markNextWatched(row)
                await viewModel.load()
            } catch {
                // L'errore si dichiara: una mutazione persa qui è un episodio che non risulta
                // visto, e l'utente non ha altro modo di accorgersene (lezione del Tracking).
                actionError = error.localizedDescription
            }
        }
    }
}
