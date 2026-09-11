import SwiftUI
import UIKit

// MARK: - Formato

/// I due tagli delle card condivisibili. Le misure sono in PUNTI a 1/3 della tela finale:
/// il renderer esporta @3x, quindi story → 1080x1920 e post → 1080x1350 pixel.
enum ShareCardFormat: String, CaseIterable, Identifiable {
    case story
    case post

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .story: return CGSize(width: 360, height: 640)
        case .post: return CGSize(width: 360, height: 450)
        }
    }

    var localizedTitle: String {
        switch self {
        case .story: return "shareCard.format.story".localized
        case .post: return "shareCard.format.post".localized
        }
    }
}

// MARK: - Card: titolo votato

/// La card "ho votato questo film/serie": poster in evidenza, stelle e recensione opzionale.
///
/// Il modello è un puro valore: poster già scaricato (`ShareCardRenderer.posterImage`),
/// niente rete e niente view model — la card deve poter essere rasterizzata al primo frame.
struct RatedTitleShareCard: View {
    struct Model {
        var title: String
        /// Voto intero 1-10 a mezze stelle, la stessa scala del server (vedi StarRatingSection).
        var rating: Int
        var review: String?
        var username: String
        /// L'indirizzo pubblico da stampare al posto della sola chiocciola (nil = niente indirizzo).
        var profileLink: String? = nil
        var poster: UIImage?
    }

    let model: Model
    var format: ShareCardFormat = .story

    private var isStory: Bool { format == .story }

    var body: some View {
        ZStack {
            ShareCardBackdrop(image: model.poster)

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                ShareCardPoster(image: model.poster, title: model.title,
                                width: isStory ? 186 : 128)

                Text(model.title)
                    .font(.system(size: isStory ? 25 : 21, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, isStory ? 22 : 14)

                ShareCardStarRow(rating: model.rating, starSize: isStory ? 22 : 18)
                    .padding(.top, isStory ? 12 : 8)

                if let review = model.review, !review.isEmpty {
                    // Virgolette tipografiche, non apici dritti: la citazione è parte del design.
                    Text("\u{201C}\(review)\u{201D}")
                        .font(.system(size: isStory ? 14.5 : 13, weight: .medium))
                        .italic()
                        .foregroundColor(.theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .lineSpacing(3)
                        .padding(.top, isStory ? 16 : 10)
                }

                ShareCardUsernameTag(username: model.username, link: model.profileLink)
                    .padding(.top, isStory ? 18 : 12)

                Spacer(minLength: 12)

                ShareCardWordmark(iconSize: isStory ? 21 : 18)
                    .padding(.bottom, isStory ? 26 : 18)
            }
            .padding(.horizontal, 30)
        }
        .frame(width: format.size.width, height: format.size.height)
    }
}

// MARK: - Card: serie completata

/// La card celebrativa "serie finita": badge, poster e la riga dei numeri che fanno scena
/// (episodi visti, ore totali quando le abbiamo).
struct ShowCompletedShareCard: View {
    struct Model {
        var title: String
        var episodesWatched: Int
        /// Ore totali già arrotondate; nil quando il runtime non è noto — la riga si accorcia.
        var totalHours: Int?
        var username: String
        /// L'indirizzo pubblico da stampare al posto della sola chiocciola (nil = niente indirizzo).
        var profileLink: String? = nil
        var poster: UIImage?
    }

    let model: Model
    var format: ShareCardFormat = .story

    private var isStory: Bool { format == .story }

    private var statsLine: String {
        var parts = [String(format: "shareCard.stats.episodes".localized, model.episodesWatched)]
        if let hours = model.totalHours, hours > 0 {
            parts.append(String(format: "shareCard.stats.hours".localized, hours))
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        ZStack {
            ShareCardBackdrop(image: model.poster)

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .heavy))
                    Text("shareCard.completedBadge".localized.uppercased())
                        .font(.system(size: 12, weight: .heavy))
                        .kerning(1.4)
                }
                .foregroundColor(.black)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.theme.accentOrange))

                ShareCardPoster(image: model.poster, title: model.title,
                                width: isStory ? 176 : 122)
                    .padding(.top, isStory ? 24 : 14)

                Text(model.title)
                    .font(.system(size: isStory ? 25 : 21, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, isStory ? 22 : 14)

                Text(statsLine)
                    .font(.system(size: isStory ? 15 : 13.5, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.top, isStory ? 10 : 7)

                ShareCardUsernameTag(username: model.username, link: model.profileLink)
                    .padding(.top, isStory ? 18 : 12)

                Spacer(minLength: 12)

                ShareCardWordmark(iconSize: isStory ? 21 : 18)
                    .padding(.bottom, isStory ? 26 : 18)
            }
            .padding(.horizontal, 30)
        }
        .frame(width: format.size.width, height: format.size.height)
    }
}

// MARK: - Card: profilo

/// La card del profilo: identità in alto, i 4 film e le 4 serie preferite come due file di
/// poster. Le liste arrivano già limitate a 4 dal chiamante ma qui c'è comunque un `prefix`:
/// una quinta copertina romperebbe la griglia calcolata sulla larghezza fissa della card.
struct ProfileShareCard: View {
    struct FavoriteItem {
        var title: String
        var poster: UIImage?
    }

    struct Model {
        var displayName: String
        var username: String
        /// L'indirizzo pubblico da stampare al posto della sola chiocciola (nil = niente indirizzo).
        var profileLink: String? = nil
        var avatar: UIImage?
        var favoriteMovies: [FavoriteItem]
        var favoriteShows: [FavoriteItem]
        var followerCount: Int?
    }

    let model: Model
    var format: ShareCardFormat = .story

    private var isStory: Bool { format == .story }
    private var tileWidth: CGFloat { isStory ? 66 : 58 }

    var body: some View {
        ZStack {
            ShareCardBackdrop(image: nil)

            VStack(spacing: 0) {
                Spacer(minLength: 10)

                ShareCardAvatar(image: model.avatar, name: model.displayName,
                                diameter: isStory ? 84 : 60)

                Text(model.displayName)
                    .font(.system(size: isStory ? 24 : 20, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, isStory ? 14 : 9)

                // Sulla card del profilo l'indirizzo prende il posto della chiocciola: è la card
                // che serve proprio a farsi trovare, e "@nicola" da solo non dice dove cercare.
                Text(model.profileLink ?? "@\(model.username)")
                    .font(.system(size: isStory ? 14.5 : 13, weight: .semibold))
                    .foregroundColor(model.profileLink == nil ? .theme.textSecondary : .theme.accentOrange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 3)

                if let followers = model.followerCount {
                    Text(String(format: "shareCard.followers".localized, followers))
                        .font(.system(size: isStory ? 13 : 12, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                        .padding(.top, isStory ? 7 : 5)
                }

                Spacer(minLength: 8)

                favoritesSection(label: "shareCard.favoriteMovies".localized,
                                 items: model.favoriteMovies)

                favoritesSection(label: "shareCard.favoriteShows".localized,
                                 items: model.favoriteShows)
                    .padding(.top, isStory ? 22 : 12)

                Spacer(minLength: 10)

                ShareCardWordmark(iconSize: isStory ? 21 : 18)
                    .padding(.bottom, isStory ? 26 : 16)
            }
            .padding(.horizontal, 28)
        }
        .frame(width: format.size.width, height: format.size.height)
    }

    @ViewBuilder
    private func favoritesSection(label: String, items: [FavoriteItem]) -> some View {
        if !items.isEmpty {
            VStack(spacing: isStory ? 10 : 7) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1.3)
                    .foregroundColor(.theme.textSecondary)

                HStack(spacing: 10) {
                    ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                        ShareCardPoster(image: item.poster, title: item.title,
                                        width: tileWidth, plain: true)
                    }
                }
            }
        }
    }
}

// MARK: - Card: wrap-up del periodo

/// Il riepilogo di un mese o di un anno: i numeri grandi in mezzo, i quattro titoli che hanno
/// occupato il periodo sotto. Le cifre arrivano già contate da `WrapUpBuilder` — la card non
/// somma, non arrotonda e non riempie: una statistica che non c'è (le ore senza runtime) sparisce
/// dalla griglia invece di comparire come zero.
struct WrapUpShareCard: View {
    struct Model {
        var periodLabel: String
        var movies: Int
        var episodes: Int
        /// nil quando i runtime non sono noti: la griglia si accorcia da tre a due riquadri.
        var hours: Int?
        var activeDays: Int
        var username: String
        /// L'indirizzo pubblico da stampare al posto della sola chiocciola (nil = niente indirizzo).
        var profileLink: String? = nil
        /// Fino a quattro poster, già scaricati. Meno di quattro va benissimo: la fila si stringe.
        var posters: [UIImage?]
        /// I titoli in chiaro, allineati ai poster: servono al ripiego quando l'immagine manca.
        var titles: [String]
    }

    let model: Model
    var format: ShareCardFormat = .story

    private var isStory: Bool { format == .story }

    private var stats: [(value: String, label: String)] {
        var entries: [(String, String)] = []
        if model.movies > 0 {
            entries.append(("\(model.movies)", "shareCard.wrapUp.movies".localized))
        }
        if model.episodes > 0 {
            entries.append(("\(model.episodes)", "shareCard.wrapUp.episodes".localized))
        }
        if let hours = model.hours, hours > 0 {
            entries.append(("\(hours)", "shareCard.wrapUp.hours".localized))
        }
        if model.activeDays > 0 {
            entries.append(("\(model.activeDays)", "shareCard.wrapUp.days".localized))
        }
        // Quattro riquadri stanno stretti anche sulla story: si tengono i primi tre, che sono
        // già ordinati dal più raccontabile.
        return Array(entries.prefix(3))
    }

    var body: some View {
        ZStack {
            ShareCardBackdrop(image: model.posters.compactMap { $0 }.first)

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                Text("shareCard.wrapUp.eyebrow".localized.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1.6)
                    .foregroundColor(.theme.accentOrange)

                Text(model.periodLabel)
                    .font(.system(size: isStory ? 30 : 25, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, isStory ? 8 : 5)

                HStack(spacing: isStory ? 12 : 9) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, entry in
                        statTile(value: entry.value, label: entry.label)
                    }
                }
                .padding(.top, isStory ? 26 : 16)

                if !model.posters.isEmpty {
                    HStack(spacing: 9) {
                        ForEach(Array(model.posters.prefix(4).enumerated()), id: \.offset) { index, poster in
                            ShareCardPoster(
                                image: poster,
                                title: index < model.titles.count ? model.titles[index] : "",
                                width: isStory ? 70 : 58,
                                plain: true)
                        }
                    }
                    .padding(.top, isStory ? 30 : 18)
                }

                ShareCardUsernameTag(username: model.username, link: model.profileLink)
                    .padding(.top, isStory ? 24 : 14)

                Spacer(minLength: 12)

                ShareCardWordmark(iconSize: isStory ? 21 : 18)
                    .padding(.bottom, isStory ? 26 : 18)
            }
            .padding(.horizontal, 26)
        }
        .frame(width: format.size.width, height: format.size.height)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: isStory ? 30 : 24, weight: .heavy))
                .foregroundColor(.theme.accentOrange)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .heavy))
                .kerning(0.9)
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: isStory ? 82 : 68)
        .padding(.vertical, isStory ? 14 : 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Card: lista

/// La copertina di una lista: nome, quanti titoli, i primi quattro poster in griglia 2x2 come
/// su `PublicListCard`. La descrizione compare solo se c'è — una riga vuota sotto il titolo
/// farebbe sembrare la card tagliata.
struct ListShareCard: View {
    struct Model {
        var name: String
        var itemCount: Int
        var description: String?
        var username: String
        /// L'indirizzo pubblico da stampare al posto della sola chiocciola (nil = niente indirizzo).
        var profileLink: String? = nil
        var posters: [UIImage?]
        var titles: [String]
    }

    let model: Model
    var format: ShareCardFormat = .story

    private var isStory: Bool { format == .story }
    private var tileWidth: CGFloat { isStory ? 92 : 74 }

    var body: some View {
        ZStack {
            ShareCardBackdrop(image: model.posters.compactMap { $0 }.first)

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .heavy))
                    Text("shareCard.list.eyebrow".localized.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(1.4)
                }
                .foregroundColor(.theme.accentOrange)

                Text(model.name)
                    .font(.system(size: isStory ? 28 : 23, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, isStory ? 10 : 6)

                Text(String(format: "shareCard.list.count".localized, model.itemCount))
                    .font(.system(size: isStory ? 14 : 12.5, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.top, isStory ? 8 : 5)

                if let description = model.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: isStory ? 13.5 : 12, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, isStory ? 10 : 6)
                }

                if !model.posters.isEmpty {
                    posterGrid
                        .padding(.top, isStory ? 26 : 14)
                }

                ShareCardUsernameTag(username: model.username, link: model.profileLink)
                    .padding(.top, isStory ? 24 : 14)

                Spacer(minLength: 12)

                ShareCardWordmark(iconSize: isStory ? 21 : 18)
                    .padding(.bottom, isStory ? 26 : 18)
            }
            .padding(.horizontal, 28)
        }
        .frame(width: format.size.width, height: format.size.height)
    }

    /// Due per riga: con quattro poster è la griglia della card lista, con due o tre la fila
    /// resta comunque bilanciata invece di lasciare un buco a destra.
    private var posterGrid: some View {
        let items = Array(model.posters.prefix(4).enumerated())
        return VStack(spacing: 9) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                HStack(spacing: 9) {
                    ForEach(items[start..<min(start + 2, items.count)], id: \.offset) { index, poster in
                        ShareCardPoster(
                            image: poster,
                            title: index < model.titles.count ? model.titles[index] : "",
                            width: tileWidth,
                            plain: true)
                    }
                }
            }
        }
    }
}

// MARK: - Pezzi condivisi

/// Il fondo di ogni card: il poster stesso, sfocato e riportato verso il colore dell'app,
/// così ogni card eredita la palette del titolo. Senza poster, due bagliori arancio sul nero.
private struct ShareCardBackdrop: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.theme.background

            if let image {
                // `opaque: true` sul blur: il bordo trasparente dello sfocato lascerebbe
                // trasparire una cornice più scura ai margini della tela.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.25)
                    .opacity(0.5)
            } else {
                RadialGradient(colors: [Color.theme.accentOrange.opacity(0.38), .clear],
                               center: UnitPoint(x: 0.5, y: 0.15),
                               startRadius: 10, endRadius: 380)
                RadialGradient(colors: [Color.theme.accentOrange.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.12, y: 0.95),
                               startRadius: 10, endRadius: 320)
            }

            // Il velo scuro cresce verso il basso: è lì che vivono testo e wordmark.
            LinearGradient(colors: [Color.theme.background.opacity(0.30),
                                    Color.theme.background.opacity(0.55),
                                    Color.theme.background.opacity(0.90)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }
}

/// Il marchio in calce: lo stesso trattamento di AppHeaderView (logo arancione + nome bianco).
private struct ShareCardWordmark: View {
    var iconSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 7) {
            Image("logo_56x56")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundColor(.theme.accentOrange)

            Text("discovery.vibeWatch".localized)
                .font(.system(size: iconSize * 0.78, weight: .bold))
                .foregroundColor(.theme.textPrimary)
        }
    }
}

/// Poster con cornice; `plain` è la variante piccola delle griglie (niente ombra teatrale).
/// Quando l'immagine manca subentra il placeholder col titolo: la card resta pubblicabile.
private struct ShareCardPoster: View {
    let image: UIImage?
    let title: String
    let width: CGFloat
    var plain: Bool = false

    private var cornerRadius: CGFloat { max(6, width * 0.09) }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ShareCardPosterPlaceholder(title: title, compact: plain)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(plain ? 0.35 : 0.55),
                radius: plain ? 8 : 22, y: plain ? 4 : 12)
    }
}

/// Il ripiego quando il poster non c'è: gradiente d'accento sfumato con il titolo sopra.
private struct ShareCardPosterPlaceholder: View {
    let title: String
    var compact: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.theme.accentOrange,
                                    Color(hex: "8a3a12"),
                                    Color.theme.background],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: 110, height: 110)
                .blur(radius: 42)
                .offset(x: -26, y: -52)

            Text(title)
                .font(.system(size: compact ? 11 : 16, weight: .heavy))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
                .padding(compact ? 6 : 14)
        }
    }
}

/// Avatar tondo con anello d'accento; senza foto, l'iniziale sul gradiente del brand.
private struct ShareCardAvatar: View {
    let image: UIImage?
    let name: String
    let diameter: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color.theme.accentOrange, Color(hex: "8a3a12")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: diameter * 0.42, weight: .heavy))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.theme.accentOrange, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 7)
    }
}

/// Cinque stelle statiche con la stessa mappatura di StarRatingSection (voto 1-10, mezzi passi)
/// e il valore numerico accanto — sulla card le stelle da sole si leggono male in piccolo.
private struct ShareCardStarRow: View {
    let rating: Int
    var starSize: CGFloat = 21

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: symbol(for: star))
                    .font(.system(size: starSize))
                    .foregroundColor(.theme.accentOrange)
                    .opacity(rating >= star * 2 - 1 ? 1 : 0.3)
            }

            Text(StarRatingSection.displayValue(for: rating))
                .font(.system(size: starSize * 0.82, weight: .heavy))
                .foregroundColor(.theme.textPrimary)
                .padding(.leading, 5)
        }
    }

    private func symbol(for star: Int) -> String {
        if rating >= star * 2 { return "star.fill" }
        if rating == star * 2 - 1 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// La firma dell'autore della card, in capsula discreta.
///
/// Con un `link` la capsula porta l'indirizzo per esteso (`vibewatchapp.com/@nicola`) invece
/// della sola chiocciola: dentro un'immagine niente è toccabile, ma un indirizzo scritto per
/// intero si legge e si digita — ed è lo stesso che viaggia come link vero nella share sheet.
private struct ShareCardUsernameTag: View {
    let username: String
    var link: String?

    var body: some View {
        Text(link ?? "@\(username)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(link == nil ? .theme.textSecondary : .theme.accentOrange)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Previews

#Preview("Rated — story") {
    RatedTitleShareCard(
        model: .init(
            title: "Interstellar",
            rating: 9,
            review: "Un viaggio che ti lascia senza fiato dal primo all'ultimo minuto. La colonna sonora da sola vale il biglietto.",
            username: "nicola",
            poster: nil
        ),
        format: .story
    )
}

#Preview("Rated — post") {
    RatedTitleShareCard(
        model: .init(title: "Dune: Part Two", rating: 7, review: nil,
                     username: "nicola", poster: nil),
        format: .post
    )
}

#Preview("Completed — story") {
    ShowCompletedShareCard(
        model: .init(title: "Breaking Bad", episodesWatched: 62, totalHours: 47,
                     username: "nicola", poster: nil),
        format: .story
    )
}

#Preview("Completed — post") {
    ShowCompletedShareCard(
        model: .init(title: "The Office", episodesWatched: 201, totalHours: nil,
                     username: "nicola", poster: nil),
        format: .post
    )
}

#Preview("Profile — story") {
    ProfileShareCard(
        model: .init(
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
        ),
        format: .story
    )
}

#Preview("Profile — post") {
    ProfileShareCard(
        model: .init(
            displayName: "Nicola",
            username: "nicola",
            avatar: nil,
            favoriteMovies: [
                .init(title: "Interstellar", poster: nil),
                .init(title: "Whiplash", poster: nil)
            ],
            favoriteShows: [
                .init(title: "Breaking Bad", poster: nil),
                .init(title: "Dark", poster: nil)
            ],
            followerCount: nil
        ),
        format: .post
    )
}
