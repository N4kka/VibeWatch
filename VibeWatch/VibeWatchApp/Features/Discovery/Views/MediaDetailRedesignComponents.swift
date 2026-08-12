import SwiftUI

// MARK: - Barra di navigazione fissa

/// Quanto è stato scrollato il contenuto di una schermata di dettaglio, in punti dall'alto.
///
/// Un `PreferenceKey` e non `onScrollGeometryChange`: il target minimo è iOS 17 e quell'API
/// arriva con la 18.
struct DetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }

    /// Il valore da mettere nello `@State`, non quello grezzo.
    ///
    /// Grezzo, la preferenza cambia a ogni fotogramma di scorrimento e ridisegna l'intera
    /// schermata di dettaglio — caroselli compresi — per una barra che deve solo sfumare. Qui si
    /// arrotonda a passi di 3 punti e si taglia a 300: oltre quella soglia la barra è già del
    /// tutto comparsa, quindi per tutto il resto della pagina il valore **non cambia più** e non
    /// si rivaluta niente.
    static func quantized(_ raw: CGFloat) -> CGFloat {
        let clamped = min(max(0, raw), 300)
        return (clamped / 3).rounded() * 3
    }
}

extension View {
    /// Misura lo scorrimento del contenuto dentro lo spazio di coordinate `space`.
    ///
    /// Va messo sul contenuto della ScrollView; la ScrollView dichiara lo stesso
    /// `.coordinateSpace(name:)` e il chiamante legge il valore con `onPreferenceChange`.
    func measuringDetailScrollOffset(in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DetailScrollOffsetKey.self,
                    value: -proxy.frame(in: .named(space)).minY
                )
            }
        )
    }
}

/// Il back button (più l'eventuale condivisione) che resta in alto mentre il contenuto scorre.
///
/// Prima i due bottoni stavano dentro l'hero, cioè dentro la ScrollView: bastavano due dita di
/// scorrimento e per tornare indietro si doveva risalire tutta la pagina, o ricordarsi dello
/// swipe dal bordo. Ora vivono in un overlay ancorato all'alto e non si muovono mai.
///
/// Fermi in cima la barra è invisibile — solo i due cerchi scuri sul backdrop, com'era — e
/// compare (sfondo + titolo) man mano che l'hero esce di scena: una barra opaca da subito
/// taglierebbe in due l'immagine di apertura, che è il pezzo di design che si sta difendendo.
struct StickyDetailNavBar: View {
    let title: String
    /// Punti scrollati dall'alto, da `DetailScrollOffsetKey`.
    let scrollOffset: CGFloat
    /// Per la pagina di una stagione, dove il titolo è sempre stato scritto nella barra.
    var showsTitleAlways = false
    let onBack: () -> Void
    var onShare: (() -> Void)?

    /// Il titolo entra quando quello grande dell'hero è ormai passato sotto la barra: averli
    /// entrambi a schermo insieme li fa sembrare un errore. In mezzo la barra resta vuota, che
    /// è come si comporta qualunque barra di navigazione.
    private var titleOpacity: Double { showsTitleAlways ? 1 : ramp(from: 210, to: 268) }

    private func ramp(from start: CGFloat, to end: CGFloat) -> Double {
        guard scrollOffset > start else { return 0 }
        return Double(min(1, (scrollOffset - start) / (end - start)))
    }

    var body: some View {
        HStack(spacing: 12) {
            circleButton(icon: "chevron.left", action: onBack)
            Spacer(minLength: 8)
            if let onShare {
                circleButton(icon: "square.and.arrow.up", action: onShare)
            }
        }
        .overlay {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(1)
                // Larghezza dei due cerchi più il respiro: un titolo lungo si tronca invece di
                // finirci sotto.
                .padding(.horizontal, 56)
                .opacity(titleOpacity)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 20)
        // Più stretta di quando i bottoni galleggiavano sull'immagine: adesso è una striscia
        // piena, e ogni punto in più è immagine coperta.
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            // Striscia piena, sempre. Prima lo sfondo sfumava dentro con lo scorrimento e nei
            // primi punti i due cerchi restavano appesi sopra l'immagine, senza niente che li
            // tenesse: la barra sembrava staccata dalla pagina. Un contenitore che c'è sempre
            // dice cos'è — la navigazione — e nasconde il contenuto che gli scorre sotto invece
            // di lasciarlo trasparire a metà.
            Color.theme.background
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
                // La barra sta dentro l'area sicura, lo sfondo no: senza questo, sotto la barra
                // scorrerebbe il contenuto nudo all'altezza dell'orologio.
                .ignoresSafeArea(edges: .top)
                // Uno sfondo trasparente resta comunque tappabile, e questo sta sopra la
                // ScrollView: senza, la striscia in alto si mangerebbe le dita che iniziano uno
                // scorrimento da lì. Interattivi restano solo i due cerchi.
                .allowsHitTesting(false)
        }
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                // Nero al 44% serviva a staccare l'icona da un backdrop qualsiasi. Ora sotto c'è
                // la striscia, e su fondo scuro un cerchio nero è una macchia più scura senza
                // motivo: si usa il riempimento chiaro delle altre superfici dell'app.
                .background(Color.white.opacity(0.09))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct MediaDetailHero: View {
    let backdropURL: URL?
    let title: String
    let year: String?
    let runtime: String?
    let genres: [String]
    let rating: String
    let voteCount: Int
    let affinityPercent: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // L'immagine sta in un overlay di un contenitore neutro: con `.fill` diretto
            // nel layout, a 340pt di altezza un backdrop 16:9 dichiara ~600pt di larghezza
            // ideale e dentro la ScrollView verticale allarga TUTTA la colonna oltre lo
            // schermo (`.clipped()` taglia il disegno, non il layout) — era la schermata
            // "stretchata" tagliata su entrambi i lati.
            Color.clear
                .overlay {
                    CachedAsyncImage(url: backdropURL, maxPixelSize: 1280)
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.18), Color.theme.background.opacity(0.16), Color.theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: 11) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 10) {
                    metadataText(year)
                    metadataDivider
                    metadataText(runtime)
                    if !genres.isEmpty {
                        metadataDivider
                        metadataText(genres.prefix(2).joined(separator: ", "))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill")
                        Text(rating)
                    }
                    .font(.system(size: 14.5, weight: .heavy))
                    .foregroundColor(.theme.accentOrange)

                    Text("(\(voteCount.formatted()) \("movieDetail.ratings".localized))")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(.theme.textSecondary)

                    Text("\(affinityPercent)% \("mediaDetail.forYou".localized)")
                        .font(.system(size: 12.5, weight: .heavy))
                        .foregroundColor(.theme.accentOrange)
                        .padding(.horizontal, 11)
                        .frame(height: 31)
                        .overlay(Capsule().stroke(Color.theme.accentOrange.opacity(0.65), lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(height: 340)
    }

    @ViewBuilder
    private func metadataText(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.theme.textSecondary)
        }
    }

    private var metadataDivider: some View {
        Text("·")
            .font(.system(size: 15, weight: .heavy))
            .foregroundColor(.theme.textSecondary)
    }
}

struct MediaProviderDisclosure: View {
    let providerState: WatchProviderLoadState
    let title: String
    let mediaType: MediaType
    let movie: Movie

    @StateObject private var listManager = ListManager.shared
    @ObservedObject private var authService = AuthService.shared
    @AppStorage("enabledMediaAvailabilityAlerts") private var enrollmentData = Data()
    @State private var isExpanded = false
    @State private var showNotifyConfirmation = false
    @State private var notificationState: MediaNotificationCTAState = .idle

    private var presentation: MediaDetailProviderPresentation {
        MediaDetailProviderPresentation.make(from: providerState)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 11) {
            if providerState.isLoading {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 220, height: 52)
            } else {
                Button(action: primaryAction) {
                    HStack(spacing: 12) {
                        if notificationState == .enabling && !presentation.canExpand {
                            ProgressView()
                                .tint(primaryForegroundColor)
                        } else if let primaryProvider, primaryProvider.hasUsableLogo {
                            // Il logo vero al posto del triangolino: "Guarda su Netflix" con
                            // accanto il simbolo generico di play era l'unico punto dell'app in
                            // cui un provider non si riconosceva a colpo d'occhio.
                            CachedAsyncImage(url: primaryProvider.logoURL, maxPixelSize: 66)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: primaryIconName)
                                .font(.system(size: 13, weight: .heavy))
                        }
                        Text(primaryTitle)
                            .font(.system(size: 15, weight: .heavy))
                        if presentation.canExpand {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .heavy))
                        }
                    }
                    .foregroundColor(primaryForegroundColor)
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .background(primaryBackgroundColor)
                    .clipShape(Capsule())
                    .shadow(
                        color: isPrimaryButtonDisabled ? .clear : Color.theme.accentOrange.opacity(0.3),
                        radius: 14,
                        y: 8
                    )
                }
                .buttonStyle(.plain)
                .disabled(isPrimaryButtonDisabled)

                if presentation.canExpand && isExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(presentation.tiers, id: \.titleKey) { tier in
                            HStack(alignment: .top, spacing: 12) {
                                Text(tier.titleKey.localized.uppercased())
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .kerning(1.25)
                                    .foregroundColor(Color(hex: "77787f"))
                                    .frame(width: 76, alignment: .leading)
                                    .padding(.top, 9)

                                FlowLayout(spacing: 7) {
                                    ForEach(tier.providers) { provider in
                                        providerChip(provider, link: tier.link)
                                    }
                                }
                            }
                        }
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "18191d"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 17)
                            .stroke(Color.white.opacity(0.13), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Il copy della conferma esiste già localizzato per le stesse notifiche in Liste: qui
        // prima era inglese scritto nel codice, in tutte e 20 le lingue.
        .alert("lists.notifyMeTitle".localized, isPresented: $showNotifyConfirmation) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text(String(format: "lists.notifyMeMessage".localized, title))
        }
        .task(id: notificationEnrollmentKey) {
            restoreNotificationState()
        }
        .onChange(of: enrollmentData) { _, _ in
            restoreNotificationState()
        }
    }

    private var primaryTitle: String {
        if let provider = presentation.primaryProviderName {
            return String(format: "lists.watchOn".localized, provider)
        }
        return notificationState.titleKey.localized
    }

    /// Il provider su cui punta la CTA: il primo del primo tier, lo stesso da cui viene il nome.
    private var primaryProvider: Provider? {
        guard presentation.canExpand else { return nil }
        return presentation.tiers.first?.providers.first
    }

    private var primaryIconName: String {
        if presentation.canExpand { return "play.fill" }
        return notificationState == .enabled ? "checkmark" : "bell.fill"
    }

    private var isPrimaryButtonDisabled: Bool {
        !presentation.canExpand && notificationState.isButtonDisabled
    }

    private var primaryForegroundColor: Color {
        isPrimaryButtonDisabled ? .theme.textSecondary : .black
    }

    private var primaryBackgroundColor: Color {
        isPrimaryButtonDisabled ? Color.white.opacity(0.1) : .theme.accentOrange
    }

    private var notificationEnrollmentKey: String {
        MediaNotificationEnrollmentCodec.key(
            userId: authService.currentUser?.id,
            mediaId: movie.id,
            mediaType: mediaType
        )
    }

    private func primaryAction() {
        if presentation.canExpand {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { isExpanded.toggle() }
        } else {
            guard notificationState == .idle else { return }
            notificationState = .enabling
            Task {
                if !listManager.isInList(listId: listManager.watchlist.id, mediaId: movie.id, mediaType: mediaType) {
                    try? await listManager.addToList(listId: listManager.watchlist.id, movie: movie, mediaType: mediaType)
                }
                do {
                    try await LiveNotificationRepository.shared.toggleAlert(
                        mediaId: movie.id,
                        mediaType: mediaType,
                        enabled: true
                    )
                    var enrolled = MediaNotificationEnrollmentCodec.decode(enrollmentData)
                    enrolled.insert(notificationEnrollmentKey)
                    enrollmentData = try MediaNotificationEnrollmentCodec.encode(enrolled)
                    notificationState = .enabled
                    showNotifyConfirmation = true
                } catch {
                    // Tornare a "Avvisami" senza dire niente sembra un tap che non ha fatto
                    // effetto: l'utente deve sapere che non è stato attivato niente.
                    notificationState = .idle
                    ToastCenter.shared.show(error: "mediaDetail.notifyMeFailed".localized)
                }
            }
        }
    }

    private func restoreNotificationState() {
        guard !presentation.canExpand else {
            notificationState = .idle
            return
        }
        let enrolled = MediaNotificationEnrollmentCodec.decode(enrollmentData)
        notificationState = enrolled.contains(notificationEnrollmentKey) ? .enabled : .idle
    }

    private func providerChip(_ provider: Provider, link: String?) -> some View {
        Button {
            PlatformDeepLinkHelper.openPlatform(provider: provider, justWatchLink: link, title: title)
        } label: {
            HStack(spacing: 7) {
                Group {
                    if provider.hasUsableLogo {
                        CachedAsyncImage(url: provider.logoURL, maxPixelSize: 66)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        // Fallback per i loghi che non sappiamo disegnare (SVG): l'iniziale.
                        ZStack {
                            Color.white.opacity(0.1)
                            Text(provider.providerName.prefix(1))
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.theme.textPrimary)
                        }
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(provider.providerName)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.white.opacity(0.075))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

}

struct MediaDetailActionStrip: View {
    @StateObject private var listManager = ListManager.shared
    let mediaId: Int
    let mediaType: MediaType
    let onWatchlist: () -> Void
    let onSeen: () -> Void
    let onLiked: () -> Void
    let onList: () -> Void

    private func contains(_ list: MediaList) -> Bool {
        list.items.contains { $0.mediaId == mediaId && $0.mediaType == mediaType }
    }

    var body: some View {
        HStack(spacing: 8) {
            action(icon: "plus", title: "mediaDetail.action.watchlist".localized,
                   active: contains(listManager.watchlist), action: onWatchlist)
            action(icon: "checkmark", title: "movieDetail.seen".localized,
                   active: contains(listManager.seenList), action: onSeen)
            action(icon: "heart.fill", title: "mediaDetail.action.like".localized,
                   active: contains(listManager.likedList), action: onLiked)
            action(icon: "list.bullet", title: "mediaDetail.action.list".localized,
                   active: false, action: onList)
        }
    }

    private func action(
        icon: String,
        title: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .heavy))
                Text(title)
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(active ? .theme.accentOrange : .theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(active ? Color.theme.accentOrange.opacity(0.12) : Color.white.opacity(0.065))
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

struct MediaWhyForMeCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("mediaDetail.why.cardTitle".localized)
                        .font(.system(size: 15.5, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                    Text("movieDetail.goodFitSubtitle".localized)
                        .font(.system(size: 12.5))
                        .foregroundColor(.theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(.horizontal, 17)
            .frame(height: 76)
            .background(Color.theme.accentOrange.opacity(0.075))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(Color.theme.accentOrange.opacity(0.55), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }
}

struct MediaDetailToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.theme.accentOrange)
            Text(message)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(.theme.textPrimary)
        }
        .padding(.horizontal, 17)
        .frame(height: 48)
        .background(.ultraThinMaterial)
        .background(Color(hex: "202126").opacity(0.94))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}
