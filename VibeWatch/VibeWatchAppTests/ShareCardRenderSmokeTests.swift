import XCTest
import SwiftUI
@testable import VibeWatchApp

/// Rasterizza la card profilo e la salva: serve a GUARDARLA, non solo a sapere che compila.
final class ShareCardRenderSmokeTests: XCTestCase {
    @MainActor
    func test_renderProfileCard() throws {
        for format in ShareCardFormat.allCases {
            let card = ProfileShareCard(
                model: .init(
                    displayName: "Nakka",
                    username: "nakka",
                    profileLink: "vibewatchapp.com/@nakka",
                    bio: "Se non finisce con una stretta di cuore non l'ho guardato davvero.",
                    avatar: nil,
                    favoriteMovies: [
                        .init(title: "Will Hunting", poster: nil),
                        .init(title: "Oppenheimer", poster: nil),
                        .init(title: "Kill Bill", poster: nil),
                        .init(title: "Eyes Wide Shut", poster: nil)
                    ],
                    favoriteShows: [
                        .init(title: "The Mentalist", poster: nil),
                        .init(title: "Pluribus", poster: nil),
                        .init(title: "Breaking Bad", poster: nil),
                        .init(title: "Dexter", poster: nil)
                    ]
                ),
                format: format
            )
            let image = try XCTUnwrap(ShareCardRenderer.render(view: card, format: format))
            let data = try XCTUnwrap(image.pngData())
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vw_profile_card_\(format.rawValue).png")
            try data.write(to: url)
            print("[card] \(url.path) \(image.size)")
        }
    }
}
