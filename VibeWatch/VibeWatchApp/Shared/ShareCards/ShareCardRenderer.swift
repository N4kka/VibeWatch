import SwiftUI
import UIKit

/// Rasterizza le card e prepara le immagini che servono ai loro modelli.
///
/// `@MainActor` non è un vezzo: `ImageRenderer` va usato dal main actor e le card leggono
/// asset e localizzazione al momento del disegno.
@MainActor
enum ShareCardRenderer {
    /// Dalla template alla tela finale: le card sono disegnate a 1/3 in punti, la scala 3
    /// porta story a 1080x1920 e post a 1080x1350 pixel. `isOpaque` perché la card copre
    /// sempre l'intera tela: un canale alfa qui sarebbe solo peso in più nel pasteboard.
    static func render(view: some View, format: ShareCardFormat) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: format.size.width, height: format.size.height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Poster TMDB pronto per una card. Passa dalla cache immagini dell'app (lo stesso
    /// URLCache di CachedAsyncImage): se il dettaglio l'ha già mostrato, qui è zero rete.
    /// `nil` sia per path mancante sia per fetch fallito — la card ha il suo placeholder.
    static func posterImage(path: String?, width: Int = 500) async -> UIImage? {
        guard let path, !path.isEmpty else { return nil }
        return await remoteImage(urlString: "https://image.tmdb.org/t/p/w\(width)\(path)")
    }

    /// Variante per URL completi (gli avatar non sono su TMDB).
    static func remoteImage(urlString: String?) async -> UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        // 1500px basta per un poster che sulla tela finale occupa poco più di metà larghezza;
        // senza il tetto terremmo in RAM bitmap full-res solo per sfocarle nel fondale.
        return try? await ImageCacheService.shared.loadImage(from: urlString, maxPixelSize: 1500)
    }
}
