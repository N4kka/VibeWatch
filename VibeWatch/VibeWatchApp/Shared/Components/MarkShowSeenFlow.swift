import SwiftUI

/// "Hai visto tutta la serie?" — la conferma, e ciò che succede dopo.
///
/// Viveva dentro `TVShowDetailView`, che è l'unico posto che aveva già stagioni ed episodi in
/// mano. Ma segnare vista una serie si fa anche dalle liste, e lì la stessa azione partiva senza
/// chiedere niente: un tap sul check di una riga marcava d'un colpo otto stagioni, senza dirlo e
/// senza mostrare quanti episodi stesse toccando. Stessa azione, stessa domanda: da qui in avanti
/// una sola.
enum MarkShowSeen {

    /// Segna vista l'intera serie. Tre effetti, e servono tutti e tre:
    ///
    /// 1. `addToList(seen)` per una serie TV **non** scrive una riga di lista: passa da
    ///    `TrackingActions.markSeen`, che riscalda il catalogo e fa scrivere al server un
    ///    `watch_event` per ogni episodio già uscito (§1.4 — il client sa *che* è vista, non
    ///    *quali* episodi la compongono). È questo che la porta "in pari" nel Tracking, e che la
    ///    fa uscire dalla watchlist: le liste TV sono derivate dallo stato, non copiate.
    /// 2. Il flag locale di `EpisodeSeenManager`, che è ciò che la lista episodi legge: senza,
    ///    SeasonView resterebbe con i check vuoti finché il pull non riporta gli eventi.
    /// 3. Il toast, perché l'espansione server non è istantanea e un tap senza risposta invita a
    ///    tapparlo di nuovo.
    @MainActor
    static func apply(show: Movie) async {
        let toastId = ToastCenter.shared.begin(message: "mediaDetail.toast.markingSeen".localized)
        do {
            try await ListManager.shared.addToList(
                listId: ListManager.shared.seenList.id, movie: show, mediaType: .tv)
            EpisodeSeenManager.shared.markShowSeen(showId: show.id)
            ToastCenter.shared.complete(
                toastId, message: "mediaDetail.toast.markedSeen".localized)
        } catch {
            ToastCenter.shared.fail(toastId, message: error.localizedDescription)
            ErrorHandler.shared.handle(error, context: "Mark show seen")
        }
    }
}

/// Il flusso completo per chi ha in mano solo una riga di lista: carica stagioni ed episodi,
/// chiede conferma, applica.
///
/// Le liste non conoscono la struttura di una serie — hanno titolo, poster e id. I numeri nella
/// conferma ("segna 62 episodi") non sono decorazione: sono la ragione per cui la domanda ha
/// senso. Quindi si caricano prima di aprire il foglio, dalla cache del dettaglio quando c'è
/// (quasi sempre: è la stessa che alimenta la pagina della serie), dalla rete quando manca.
@MainActor
final class MarkShowSeenFlow: ObservableObject {
    struct Pending: Identifiable {
        let show: Movie
        let seasons: [Season]
        var id: Int { show.id }

        var seasonCount: Int { seasons.count }
        var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodeCount } }
    }

    /// La serie con il foglio a schermo.
    @Published private(set) var pending: Pending?
    /// La serie di cui si stanno caricando le stagioni: la riga ci mette la rotella, così un tap
    /// su una cache fredda non sembra ignorato.
    @Published private(set) var loadingShowId: Int?

    private let loadSeasons: (Int) async -> [Season]

    init(loadSeasons: @escaping (Int) async -> [Season] = MarkShowSeenFlow.seasonsFromDetailCache) {
        self.loadSeasons = loadSeasons
    }

    /// Gli speciali non si contano: non entrano nel progresso (§1.3) e includerli nel numero
    /// prometterebbe un conteggio che il server poi non scrive.
    static func seasonsFromDetailCache(showId: Int) async -> [Season] {
        for await snapshot in LiveMediaDetailRepository.shared.observeTVShow(id: showId) {
            return snapshot.tvShow.seasons?.filter { $0.seasonNumber > 0 } ?? []
        }
        return []
    }

    func start(show: Movie) async {
        guard pending == nil, loadingShowId == nil else { return }
        loadingShowId = show.id
        let seasons = await loadSeasons(show.id)
        loadingShowId = nil
        // Zero stagioni vuol dire che il dettaglio non è arrivato (offline, o una serie che TMDB
        // non conosce). Si chiede lo stesso: la conferma senza numeri è meno utile, ma sparire in
        // silenzio dopo un tap è peggio, e l'azione dopo funziona comunque.
        pending = Pending(show: show, seasons: seasons)
    }

    func cancel() { pending = nil }

    func confirm() async {
        guard let pending else { return }
        self.pending = nil
        await MarkShowSeen.apply(show: pending.show)
    }
}

extension View {
    /// Attacca il foglio di conferma del flusso. Va messo una volta per schermata.
    func markShowSeenFlow(_ flow: MarkShowSeenFlow) -> some View {
        modifier(MarkShowSeenFlowModifier(flow: flow))
    }
}

private struct MarkShowSeenFlowModifier: ViewModifier {
    @ObservedObject var flow: MarkShowSeenFlow

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { flow.pending != nil },
                set: { if !$0 { flow.cancel() } })
        ) {
            if let pending = flow.pending {
                MarkAllSeenConfirmationSheet(
                    posterURL: pending.show.posterURL,
                    showName: pending.show.title,
                    seasonCount: pending.seasonCount,
                    episodeCount: pending.episodeCount,
                    onConfirm: { Task { await flow.confirm() } },
                    onCancel: { flow.cancel() }
                )
                .vwModalPresentation()
            }
        }
    }
}

// MARK: - Il foglio

struct MarkAllSeenConfirmationSheet: View {
    let posterURL: URL?
    let showName: String
    let seasonCount: Int
    let episodeCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VWModalSheet(
            title: "tvDetail.markAllSeenTitle".localized,
            subtitle: "tvDetail.markAllSeenSubtitle".localized,
            onClose: onCancel,
            primaryTitle: String(format: "tvDetail.markAllSeenCTA".localized, episodeCount),
            primaryAction: onConfirm,
            secondaryTitle: "common.cancel".localized,
            secondaryAction: onCancel
        ) {
            VStack(spacing: 14) {
                showCard
                summaryCard
                reversibleNote
            }
        }
    }

    private var showCard: some View {
        HStack(spacing: 14) {
            Group {
                if let posterURL {
                    CachedAsyncImage(url: posterURL, maxPixelSize: 300)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 52, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(showName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)

                Text(subtitleCounts)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var subtitleCounts: String {
        let seasons = String(format: "tvDetail.seasonsCount".localized, seasonCount)
        let episodes = String(format: "tvDetail.episodesCount".localized, episodeCount)
        return "\(seasons) · \(episodes)"
    }

    private var summaryCard: some View {
        // La riga "esperienza guadagnata" della reference non c'è: la gamification non espone
        // un XP per episodio visto, e un numero inventato sarebbe peggio di una riga in meno.
        VStack(spacing: 18) {
            VWModalSummaryRow(
                icon: "checkmark",
                iconColor: .green,
                title: "tvDetail.markAllSeen.episodes".localized,
                value: "\(episodeCount)",
                valueColor: .green
            )
            VWModalSummaryRow(
                icon: "line.3.horizontal",
                iconColor: .theme.textSecondary,
                title: "tvDetail.markAllSeen.diary".localized,
                value: String(format: "tvDetail.seasonsCount".localized, seasonCount)
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
    }

    private var reversibleNote: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
            Text("tvDetail.markAllSeenReversible".localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
