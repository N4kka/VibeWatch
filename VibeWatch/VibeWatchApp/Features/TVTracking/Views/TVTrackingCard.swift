import SwiftUI

/// SPEC v3 §9.2 — la card di una serie nella schermata Tracking.
///
/// **Questa View non calcola niente.** La versione precedente derivava qui progresso, prossimo
/// episodio, ultimo visto e conteggi, con una sessantina di righe di computed properties su
/// `seenKeys` più una chiamata TMDB per card (N+2 per apertura della tab). §1.1 dice di
/// **eliminare** quella logica, non di spostarla in un ViewModel: vive in Postgres, il client la
/// legge da `v_tv_tracking` e la disegna. È ciò che rende possibile §13.6 — zero rete, sotto i
/// 300 ms — e ciò che evita di riscriverla una seconda volta in TypeScript per la web app.
struct TVTrackingCard: View {
    let row: TrackingRow
    /// L'azione è partita e il server non ha ancora risposto. Serve perché il progresso lo
    /// ricalcola il server (§1.1): fra il tap e la card aggiornata c'è un giro di rete, e senza
    /// dirlo un utente che non vede niente tocca di nuovo — marcando due episodi invece di uno.
    var isBusy: Bool = false
    var onMarkWatched: () -> Void = {}
    var onSnooze: () -> Void = {}

    @State private var navigate = false
    /// La card celebrativa "serie finita" (social feed M1). Item-based: il foglio nasce col
    /// poster già scaricato e la firma già risolta.
    @State private var shareItem: CompletedShareItem?
    @State private var isPreparingShare = false

    /// "In pari" è un fatto del bucket, non l'assenza del prossimo episodio: una riga senza
    /// catalogo (serie appena aggiunta alla watchlist, mai risolta) ha `nextLabel == nil` in
    /// QUALSIASI bucket, e disegnarle il check verde la faceva sembrare "vista" in "Da iniziare".
    private var isCaughtUp: Bool { row.bucket == .upToDate && row.nextLabel == nil }

    /// COMPLETATA è più stretto di "in pari": nessuna stagione futura annunciata (stessa
    /// semantica di `fusedListRows.isSeen`) e almeno un episodio visto — condividere il
    /// traguardo di una serie mai iniziata sarebbe una card che mente.
    private var isCompleted: Bool {
        row.bucket == .upToDate && row.nextSeason == nil && row.watchedCount > 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            poster
                .frame(width: 116, height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                header
                if let episodeName = row.nextEpisodeName, !episodeName.isEmpty {
                    Text(episodeName)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
                // "Dove lo guardo": streaming > noleggio > acquisto > avvisami. NON è il
                // duplicato del segno di spunta che questa card ha già tolto una volta — quello
                // scriveva, questa apre la piattaforma (o promette l'avviso).
                WatchProviderPill(mediaId: row.showId, mediaType: .tv,
                                  title: row.showName ?? "")
                Spacer(minLength: 4)
                progressBar
            }
            .padding(.vertical, 2)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture { navigate = true }
        .navigationDestination(isPresented: $navigate) {
            TVShowDetailView(tvShowId: row.showId)
        }
        .sheet(item: $shareItem) { item in
            ShareCardSheet(content: item.content, onClose: { shareItem = nil })
        }
        // §9.2: swipe → segna visto, ← rimanda.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { onSnooze() } label: {
                Label("tracking.action.later".localized, systemImage: "clock.arrow.circlepath")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { onMarkWatched() } label: {
                Label("tracking.action.watched".localized, systemImage: "checkmark")
            }
            .tint(.green)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                // Senza prossimo episodio l'utente è in pari — ma solo se il bucket lo dice:
                // per una riga senza catalogo "In pari" sarebbe falso, si tace in attesa
                // che il self-heal risolva la serie.
                Text(row.nextLabel ?? (isCaughtUp ? "tracking.caughtUp".localized : " "))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(row.nextLabel == nil ? .theme.textSecondary : .theme.textPrimary)

                // Una serie il cui catalogo non è ancora stato risolto arriva senza nome: succede
                // durante un import, ed è meglio di farla sparire dalla lista.
                Text(row.showName ?? "tracking.unknownShow".localized)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(spacing: 8) {
                markButton
                // Il momento di condivisione vive solo sulle serie FINITE: sulla card in
                // pari-per-ora non c'è nessun traguardo da celebrare.
                if isCompleted {
                    shareButton
                }
            }
        }
    }

    private var shareButton: some View {
        Button(action: prepareShare) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 34, height: 34)
                if isPreparingShare {
                    ProgressView().scaleEffect(0.7).tint(.theme.textSecondary)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isPreparingShare)
        .accessibilityLabel(Text("shareCard.share".localized))
    }

    /// Prima si preparano poster e firma, poi si apre il foglio: mai una card a metà.
    /// Le ore totali restano nil di proposito — lo specchio `tv_show_state` non porta i
    /// runtime, e la card sa accorciare la riga dei numeri.
    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            let poster = await ShareCardRenderer.posterImage(path: row.posterPath)
            let username = await ShareCardIdentity.username()
            shareItem = CompletedShareItem(content: .showCompleted(.init(
                title: row.showName ?? "tracking.unknownShow".localized,
                episodesWatched: row.watchedCount,
                totalHours: nil,
                username: username,
                poster: poster
            )))
            isPreparingShare = false
        }
    }

    /// Wrapper Identifiable per `.sheet(item:)`.
    fileprivate struct CompletedShareItem: Identifiable {
        let id = UUID()
        let content: ShareCardContent
    }

    private var markButton: some View {
        Button(action: onMarkWatched) {
            ZStack {
                Circle()
                    .fill(isCaughtUp ? Color.green.opacity(0.25) : Color.white.opacity(0.18))
                    .frame(width: 34, height: 34)
                if isBusy {
                    ProgressView().scaleEffect(0.7).tint(.theme.textSecondary)
                } else {
                    Image(systemName: isCaughtUp ? "checkmark.circle.fill" : "checkmark")
                        .font(.system(size: isCaughtUp ? 20 : 15, weight: .semibold))
                        .foregroundColor(isCaughtUp ? .green : .theme.textSecondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        // In pari o senza catalogo: non c'è un prossimo episodio da marcare. Un tap che
        // scrivesse qualcosa qui dovrebbe inventare quale episodio.
        .disabled(row.nextLabel == nil || isBusy)
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(Color.theme.accentOrange)
                        .frame(width: max(0, geo.size.width * row.progress))
                }
            }
            .frame(height: 4)

            // Il denominatore è ciò che è USCITO, non il totale della serie: dire "3/24" a chi ha
            // visto tutti e 3 gli episodi trasmessi è tecnicamente vero e praticamente sbagliato.
            Text("\(row.watchedCount)/\(row.airedCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.theme.textSecondary)
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let path = row.posterPath,
           let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
            CachedAsyncImage(url: url, maxPixelSize: 500) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
            }
        } else {
            Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
                .overlay { Image(systemName: "tv").foregroundColor(.theme.textSecondary) }
        }
    }
}
