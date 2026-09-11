import UIKit

/// Condivisione diretta su Instagram Stories via URL scheme documentato da Meta.
///
/// Il canale è tutto qui: l'immagine finisce nel pasteboard sotto la chiave che Instagram
/// legge all'apertura dello scheme. Richiede `instagram-stories` in LSApplicationQueriesSchemes
/// (Info.plist), altrimenti `canOpenURL` risponde sempre false.
@MainActor
enum InstagramStoriesSharer {
    private static let scheme = "instagram-stories"

    /// False quando Instagram non è installato: il chiamante nasconde il bottone dedicato.
    static var canShare: Bool {
        guard let url = URL(string: "\(scheme)://share") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Mette la card nel pasteboard e apre Instagram. Ritorna false quando lo scheme non è
    /// apribile (app rimossa fra il check e il tap): il chiamante ripiega sulla share sheet.
    ///
    /// `contentURL` è l'indirizzo del profilo. Instagram lo onora solo per le app abilitate al
    /// link nelle storie, quindi **non è la strada principale**: l'indirizzo è comunque scritto
    /// sulla card, dove si legge sempre. Metterlo qui costa una chiave e non rompe niente se
    /// Instagram lo ignora — e il giorno che l'app fosse abilitata funzionerebbe da solo.
    @discardableResult
    static func share(image: UIImage, contentURL: URL? = nil) -> Bool {
        guard canShare,
              let imageData = image.pngData(),
              let url = URL(string: "\(scheme)://share?source_application=\(Bundle.main.bundleIdentifier ?? "")")
        else { return false }

        var item: [String: Any] = ["com.instagram.sharedSticker.backgroundImage": imageData]
        if let contentURL {
            item["com.instagram.sharedSticker.contentURL"] = contentURL.absoluteString
        }

        // La scadenza evita che un PNG da megabyte resti nel pasteboard di sistema ben oltre
        // la condivisione; 10 minuti coprono anche l'utente che si perde dentro Instagram.
        UIPasteboard.general.setItems(
            [item],
            options: [.expirationDate: Date().addingTimeInterval(60 * 10)]
        )
        UIApplication.shared.open(url)
        return true
    }
}
