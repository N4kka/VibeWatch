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
    @discardableResult
    static func share(image: UIImage) -> Bool {
        guard canShare,
              let imageData = image.pngData(),
              let url = URL(string: "\(scheme)://share?source_application=\(Bundle.main.bundleIdentifier ?? "")")
        else { return false }

        // La scadenza evita che un PNG da megabyte resti nel pasteboard di sistema ben oltre
        // la condivisione; 10 minuti coprono anche l'utente che si perde dentro Instagram.
        UIPasteboard.general.setItems(
            [["com.instagram.sharedSticker.backgroundImage": imageData]],
            options: [.expirationDate: Date().addingTimeInterval(60 * 10)]
        )
        UIApplication.shared.open(url)
        return true
    }
}
