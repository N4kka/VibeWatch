import SwiftUI

/// Card di raccomandazione nella chat Vibe AI: poster con badge match %, titolo, meta, motivo
/// personalizzato e azioni "+ Aggiungi" / "Dettagli".
struct AIRecommendationCardView: View {
    let card: AIRecommendationCardModel
    let isInWatchlist: Bool
    let onAdd: () -> Void
    let onDetails: () -> Void

    private var posterURL: URL? {
        guard let path = card.posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
    }

    private var metaLine: String {
        var parts: [String] = []
        if let seasonsOrRuntime = card.seasonsOrRuntime { parts.append(seasonsOrRuntime) }
        if let country = card.country { parts.append(country) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: posterURL, maxPixelSize: 342) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.06))
                }
                .frame(width: 76, height: 106)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("\(card.matchPercent)%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.theme.accentOrange)
                    .clipShape(Capsule())
                    .offset(x: -4, y: 6)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.theme.textPrimary)
                        .lineLimit(2)
                    if let year = card.year {
                        Text(year)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.theme.textSecondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(card.mediaType == .tv ? "ai.card.series".localized : "ai.card.movie".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())

                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                if !card.reason.isEmpty {
                    Text(card.reason)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(action: onAdd) {
                        Text(isInWatchlist ? "ai.card.added".localized : "ai.card.add".localized)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isInWatchlist ? Color.theme.textSecondary : Color.theme.accentOrange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().stroke(
                                    isInWatchlist ? Color.theme.separator : Color.theme.accentOrange.opacity(0.8),
                                    lineWidth: 1.2
                                )
                            )
                    }
                    .disabled(isInWatchlist)
                    .buttonStyle(.plain)

                    Button(action: onDetails) {
                        Text("ai.card.details".localized)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.09))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
