import SwiftUI

struct KnownForHighlightCard: View {
    let credit: PersonCredit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("actor.known_for".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            NavigationLink(destination: destinationView) {
                ActorFilmographyRow(credit: credit)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.theme.accentOrange.opacity(0.6), lineWidth: 1.5)
                    )
                    .shadow(color: Color.theme.accentOrange.opacity(0.2), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch credit.mediaType {
        case .movie: MovieDetailView(movieId: credit.id)
        case .tv:    TVShowDetailView(tvShowId: credit.id)
        }
    }
}
