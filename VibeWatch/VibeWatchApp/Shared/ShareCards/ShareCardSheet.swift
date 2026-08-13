import SwiftUI
import UIKit

/// Il contenuto condivisibile: una card per tipo, il foglio è lo stesso per tutte.
enum ShareCardContent {
    case ratedTitle(RatedTitleShareCard.Model)
    case showCompleted(ShowCompletedShareCard.Model)
    case profile(ProfileShareCard.Model)
    case wrapUp(WrapUpShareCard.Model)
    case list(ListShareCard.Model)
}

/// Il foglio di condivisione: anteprima dal vivo della card, scelta del taglio (story/post)
/// e due uscite — Instagram Stories quando l'app c'è, altrimenti la share sheet di sistema.
///
/// Va presentato come le altre modali ridisegnate:
/// `.sheet(isPresented:) { ShareCardSheet(content: ..., onClose: ...) }` — la presentazione
/// `vwModalPresentation` è già applicata qui dentro.
struct ShareCardSheet: View {
    let content: ShareCardContent
    /// L'indirizzo del profilo a cui la card rimanda. Viaggia **accanto** all'immagine nella
    /// share sheet di sistema: dentro un PNG niente è toccabile, ma su WhatsApp o in Messaggi
    /// chi riceve si ritrova un link vero, e quel link apre l'app sul profilo giusto
    /// (universal link §9.4). `nil` quando non c'è uno username: meglio nessun link che uno rotto.
    var link: URL?
    var onClose: () -> Void

    @State private var format: ShareCardFormat = .story
    /// Item-based così la share sheet di sistema nasce già con l'immagine renderizzata.
    @State private var systemShareImage: SystemShareImage?
    /// Letto a comparsa e mai più: `canOpenURL` non cambia mentre il foglio è aperto, e
    /// leggerlo nell'init violerebbe l'isolamento MainActor dello sharer.
    @State private var instagramAvailable = false

    /// L'altezza fissa dell'anteprima: i due tagli hanno proporzioni diverse e senza un
    /// vincolo comune il foglio salterebbe di altezza a ogni cambio di formato.
    private let previewHeight: CGFloat = 300

    var body: some View {
        VWModalSheet(
            title: "shareCard.sheet.title".localized,
            onClose: onClose,
            primaryTitle: instagramAvailable
                ? "shareCard.instagramStories".localized
                : "shareCard.share".localized,
            primaryAction: primaryAction,
            secondaryTitle: instagramAvailable ? "shareCard.moreOptions".localized : nil,
            secondaryAction: instagramAvailable ? presentSystemShare : nil
        ) {
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    SegmentedPicker(items: ShareCardFormat.allCases,
                                    selection: $format,
                                    label: { $0.localizedTitle })
                    Spacer()
                }

                cardPreview
                    .frame(maxWidth: .infinity)
            }
        }
        .vwModalPresentation()
        .onAppear { instagramAvailable = InstagramStoriesSharer.canShare }
        .sheet(item: $systemShareImage) { item in
            // Immagine e link insieme: le app che sanno gestire entrambi (Messaggi, WhatsApp,
            // Mail) mostrano la card E il link cliccabile; quelle che ne prendono uno solo
            // scelgono l'immagine, che è comunque la parte che si guarda.
            ShareSheet(items: [item.image] + (link.map { [$0] } ?? []))
        }
    }

    // MARK: - Anteprima

    /// La stessa vista che verrà rasterizzata, rimpicciolita a scala intera: niente mockup
    /// separato che poi diverge dall'immagine vera.
    private var cardPreview: some View {
        let size = format.size
        let scale = previewHeight / size.height

        return card(in: format)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: format)
    }

    @ViewBuilder
    private func card(in format: ShareCardFormat) -> some View {
        switch content {
        case .ratedTitle(let model):
            RatedTitleShareCard(model: model, format: format)
        case .showCompleted(let model):
            ShowCompletedShareCard(model: model, format: format)
        case .profile(let model):
            ProfileShareCard(model: model, format: format)
        case .wrapUp(let model):
            WrapUpShareCard(model: model, format: format)
        case .list(let model):
            ListShareCard(model: model, format: format)
        }
    }

    // MARK: - Azioni

    private func primaryAction() {
        if instagramAvailable {
            shareToInstagram()
        } else {
            presentSystemShare()
        }
    }

    /// Il render è sincrono e raro: nessuno spinner, ma il fallimento si dichiara col toast
    /// invece di lasciare un tap che non fa niente.
    private func renderedCard() -> UIImage? {
        let image = ShareCardRenderer.render(view: card(in: format), format: format)
        if image == nil {
            ToastCenter.shared.show(error: "shareCard.toast.renderFailed".localized)
        }
        return image
    }

    private func shareToInstagram() {
        guard let image = renderedCard() else { return }
        if InstagramStoriesSharer.share(image: image, contentURL: link) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Il foglio ha finito il suo compito: l'utente sta passando a Instagram e al
            // ritorno non deve ritrovarsi la modale aperta.
            onClose()
        } else {
            // Instagram sparito fra il check e il tap: si ripiega senza un errore in faccia.
            systemShareImage = SystemShareImage(image: image)
        }
    }

    private func presentSystemShare() {
        guard let image = renderedCard() else { return }
        systemShareImage = SystemShareImage(image: image)
    }
}

/// Wrapper Identifiable per `.sheet(item:)`: UIImage da sola non basta.
private struct SystemShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

#Preview("Share sheet — rated") {
    Color.theme.background
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ShareCardSheet(
                content: .ratedTitle(.init(
                    title: "Interstellar",
                    rating: 9,
                    review: "Un viaggio che ti lascia senza fiato.",
                    username: "nicola",
                    poster: nil
                )),
                onClose: {}
            )
        }
}

#Preview("Share sheet — profile") {
    Color.theme.background
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ShareCardSheet(
                content: .profile(.init(
                    displayName: "Nicola",
                    username: "nicola",
                    avatar: nil,
                    favoriteMovies: [
                        .init(title: "Interstellar", poster: nil),
                        .init(title: "Whiplash", poster: nil),
                        .init(title: "La La Land", poster: nil),
                        .init(title: "Parasite", poster: nil)
                    ],
                    favoriteShows: [
                        .init(title: "Breaking Bad", poster: nil),
                        .init(title: "Dark", poster: nil),
                        .init(title: "Severance", poster: nil),
                        .init(title: "The Bear", poster: nil)
                    ],
                    followerCount: 128
                )),
                onClose: {}
            )
        }
}
