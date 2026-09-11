import SwiftUI
import UIKit

/// Il pulsante "condividi questa lista", con la sua trafila dentro (poster, firma, foglio) —
/// gemello di `WrapUpShareButton` e per lo stesso motivo: la lista si condivide sia dalla propria
/// (`CustomListDetailView`) sia da una pubblica altrui, e sono lo stesso gesto.
///
/// **Una lista vuota non produce una card.** Quattro riquadri di ripiego sotto un nome non
/// raccontano niente: si dice che non c'è ancora niente da mostrare e non si apre nulla.
struct ListShareButton: View {
    /// Ciò che serve alla card, da qualunque delle due liste arrivi: il pulsante non conosce
    /// né `MediaList` né `PublicList`, così non deve cambiare quando cambia uno dei due.
    struct Source {
        var name: String
        var itemCount: Int
        var description: String?
        /// Fino a quattro copertine, nell'ordine in cui devono comparire.
        var posterPaths: [String]
        var titles: [String]
        /// L'autore della lista: nil sulla propria (si firma con l'identità in sessione).
        var authorUsername: String?
    }

    let source: Source

    @State private var isBuilding = false
    @State private var shareTarget: ListShareTarget?

    var body: some View {
        Button {
            Task { await build() }
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
        .accessibilityLabel(Text("shareCard.list.action".localized))
        .sheet(item: $shareTarget) { target in
            ShareCardSheet(content: target.content, link: target.link, onClose: { shareTarget = nil })
        }
    }

    private func build() async {
        guard source.itemCount > 0 else {
            ToastCenter.shared.show(error: "shareCard.list.empty".localized)
            return
        }
        isBuilding = true
        defer { isBuilding = false }

        var posters: [UIImage?] = []
        for path in source.posterPaths.prefix(4) {
            posters.append(await ShareCardRenderer.posterImage(path: path))
        }

        // La firma (e l'indirizzo) sono dell'AUTORE della lista, non di chi condivide: una
        // lista altrui che esce col nome sbagliato è un'attribuzione falsa, non un dettaglio
        // di stile — e il link deve portare al suo profilo, non al mio.
        let identity: ShareCardIdentity.Identity
        if let author = source.authorUsername {
            identity = .other(username: author)
        } else {
            identity = await ShareCardIdentity.current()
        }

        shareTarget = ListShareTarget(
            content: .list(.init(
                name: source.name,
                itemCount: source.itemCount,
                description: source.description,
                username: identity.handle,
                profileLink: identity.drawnLink,
                posters: posters,
                titles: source.titles)),
            link: identity.profileURL)
    }
}

private struct ListShareTarget: Identifiable {
    let id = UUID()
    let content: ShareCardContent
    /// L'indirizzo del profilo dell'autore della lista.
    let link: URL?
}

extension ListShareButton.Source {
    /// Dalla propria lista: le copertine sono quelle degli item più recenti, come sulla card
    /// del feed liste (`PublicListCard`) — la stessa lista deve avere la stessa faccia ovunque.
    init(list: MediaList) {
        let covers = list.items
            .sorted { $0.addedAt > $1.addedAt }
            .filter { $0.posterPath != nil }
            .prefix(4)
        self.init(
            name: list.displayName,
            itemCount: list.items.count,
            description: list.description,
            posterPaths: covers.compactMap { $0.posterPath },
            titles: covers.map { $0.title },
            authorUsername: nil)
    }

    /// Da una lista pubblica: le copertine arrivano già scelte dal server, e i titoli no —
    /// `get_public_lists` non li porta. La griglia li usa solo come ripiego per un poster
    /// mancante, e un ripiego vuoto è meglio di un titolo inventato.
    init(publicList: PublicList) {
        self.init(
            name: publicList.name,
            itemCount: publicList.itemCount,
            description: publicList.description,
            posterPaths: Array(publicList.coverPosterPaths.prefix(4)),
            titles: [],
            authorUsername: publicList.ownerUsername)
    }
}
