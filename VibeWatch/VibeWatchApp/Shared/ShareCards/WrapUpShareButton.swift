import SwiftUI
import UIKit

/// Il pulsante "condividi il tuo periodo", con tutta la sua trafila dentro: scelta del periodo,
/// conteggio dallo specchio locale, poster scaricati e foglio di condivisione.
///
/// È un pezzo unico e non tre stati sparsi nella schermata ospite perché gli ospiti sono due
/// (analytics e diario) e la logica è identica: duplicarla vorrebbe dire che il prossimo ritocco
/// ne aggiusta una e dimentica l'altra.
///
/// **Un periodo vuoto non produce una card.** Se in quel mese non risulta niente, lo si dice e
/// non si apre nulla: una card che annuncia "0 film, 0 episodi" non è un riepilogo, è una
/// figuraccia pubblicata.
struct WrapUpShareButton: View {
    var builder: WrapUpBuilder = .shared

    @State private var showPeriodPicker = false
    @State private var isBuilding = false
    @State private var shareTarget: WrapUpShareTarget?

    private let periods = WrapUpPeriod.suggestions()

    var body: some View {
        Button {
            showPeriodPicker = true
        } label: {
            if isBuilding {
                ProgressView().tint(.theme.textPrimary)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
            }
        }
        .disabled(isBuilding)
        .accessibilityLabel(Text("shareCard.wrapUp.action".localized))
        .confirmationDialog(
            "shareCard.wrapUp.pickPeriod".localized,
            isPresented: $showPeriodPicker,
            titleVisibility: .visible
        ) {
            ForEach(periods) { period in
                Button(period.localizedLabel()) {
                    Task { await build(period) }
                }
            }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .sheet(item: $shareTarget) { target in
            ShareCardSheet(content: target.content, link: target.link, onClose: { shareTarget = nil })
        }
    }

    private func build(_ period: WrapUpPeriod) async {
        isBuilding = true
        defer { isBuilding = false }

        let summary = await builder.summary(for: period)
        guard !summary.isEmpty else {
            ToastCenter.shared.show(error: "shareCard.wrapUp.empty".localized)
            return
        }

        // I poster in sequenza e non in parallelo: sono al massimo quattro e passano quasi
        // sempre dalla cache immagini: una task group qui sarebbe cerimonia senza guadagno.
        var posters: [UIImage?] = []
        for title in summary.topTitles {
            posters.append(await ShareCardRenderer.posterImage(path: title.posterPath))
        }

        let identity = await ShareCardIdentity.current()
        shareTarget = WrapUpShareTarget(
            content: .wrapUp(.init(
                periodLabel: summary.period.localizedLabel(),
                movies: summary.movies,
                episodes: summary.episodes,
                hours: summary.hours,
                activeDays: summary.activeDays,
                username: identity.handle,
                profileLink: identity.drawnLink,
                posters: posters,
                titles: summary.topTitles.map { $0.title ?? "" })),
            link: identity.profileURL)
    }
}

/// Wrapper Identifiable per `sheet(item:)`: `ShareCardContent` è un enum senza identità.
private struct WrapUpShareTarget: Identifiable {
    let id = UUID()
    let content: ShareCardContent
    /// L'indirizzo del profilo che accompagna la card nella share sheet.
    let link: URL?
}
