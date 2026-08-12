import SwiftUI

/// Lo scheletro del dettaglio, film e serie.
///
/// Prima al suo posto c'era un `ProgressView()` nudo a mezzo schermo: la pagina appariva vuota e
/// poi saltava in posizione. Qui la forma della pagina c'è già — hero, strip delle azioni, chip,
/// testo, card e cast — e quando i dati arrivano niente si sposta.
struct MediaDetailSkeletonView: View {
    var body: some View {
        VStack(spacing: 0) {
            hero

            VStack(alignment: .leading, spacing: 20) {
                actionStrip
                chips
                overview
                bigCard
                castRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .shimmering()
        .accessibilityHidden(true)
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            SkeletonBlock(cornerRadius: 0)
                .frame(height: 340)

            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 38, height: 38)
                .padding(.leading, 20)
                .padding(.top, 56)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(cornerRadius: 5)
                    .frame(width: 130, height: 14)
                SkeletonBlock(cornerRadius: 8)
                    .frame(width: 230, height: 30)
            }
            .padding(.leading, 20)
            .padding(.bottom, 22)
        }
    }

    private var actionStrip: some View {
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(cornerRadius: 14)
                    .frame(height: 62)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 12) {
            SkeletonBlock(cornerRadius: 14)
                .frame(width: 130, height: 44)
            SkeletonBlock(cornerRadius: 14)
                .frame(width: 150, height: 44)
            Spacer(minLength: 0)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 9) {
            SkeletonBlock(cornerRadius: 5).frame(height: 12)
            SkeletonBlock(cornerRadius: 5).frame(height: 12).padding(.trailing, 32)
            SkeletonBlock(cornerRadius: 5).frame(height: 12).padding(.trailing, 120)
        }
    }

    private var bigCard: some View {
        SkeletonBlock(cornerRadius: 20)
            .frame(height: 360)
    }

    private var castRow: some View {
        HStack(spacing: 22) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(spacing: 10) {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 66, height: 66)
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 56, height: 8)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
