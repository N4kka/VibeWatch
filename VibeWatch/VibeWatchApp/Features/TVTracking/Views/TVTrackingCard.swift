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
                // Senza prossimo episodio l'utente è in pari: si dice, invece di mostrare un
                // "S1E1" di ripiego che sarebbe semplicemente falso.
                Text(row.nextLabel ?? "tracking.caughtUp".localized)
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
            markButton
        }
    }

    private var markButton: some View {
        Button(action: onMarkWatched) {
            ZStack {
                Circle()
                    .fill(row.nextLabel == nil ? Color.green.opacity(0.25) : Color.white.opacity(0.18))
                    .frame(width: 34, height: 34)
                if isBusy {
                    ProgressView().scaleEffect(0.7).tint(.theme.textSecondary)
                } else {
                    Image(systemName: row.nextLabel == nil ? "checkmark.circle.fill" : "checkmark")
                        .font(.system(size: row.nextLabel == nil ? 20 : 15, weight: .semibold))
                        .foregroundColor(row.nextLabel == nil ? .green : .theme.textSecondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        // In pari: non c'è un prossimo episodio da marcare, e il segno di spunta pieno lo dice
        // già. Un tap che scrivesse qualcosa qui dovrebbe inventare quale episodio.
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
