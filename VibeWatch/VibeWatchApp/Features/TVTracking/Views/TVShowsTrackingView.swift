import SwiftUI

/// SPEC v3 §9.2 — la schermata che l'utente TV Time apre ogni giorno.
///
/// "Da guardare" in cima perché è il motivo per cui la schermata esiste; il resto chiuso di
/// default perché sono elenchi lunghi che non servono ogni giorno. La timeline delle uscite
/// che §9.2 metteva qui sotto NON c'è più (Redesign 2.0, deciso dall'utente il 2026-08-03):
/// a "cosa esce" risponde il calendario — l'icona qui in alto e la strip in Scopri — che
/// legge le stesse righe di `tv_timeline`.
///
/// La versione precedente era un selettore a tre segmenti su liste ricavate dal client. Non è
/// stata adattata ma sostituita: i bucket ora sono sette e li decide il server (§3.4), e un
/// segmented control su sette voci non è una schermata che si apre ogni mattina.
///
/// Nessun caricamento di rete qui dentro. È un requisito (§13.6), non un'ottimizzazione.
struct TVShowsTrackingView: View {
    @StateObject private var viewModel = TVShowsTrackingViewModel()
    @State private var actionError: String?
    /// La serie su cui c'è un'azione in volo. Il progresso lo ricalcola il server, quindi fra il
    /// tap e la card aggiornata passa un giro di rete: senza dirlo, chi non vede niente tocca di
    /// nuovo e si ritrova due episodi marcati invece di uno.
    @State private var busyShowId: Int?
    /// §13.6 si misura sulla PRIMA apertura: dopo, la cache di SwiftUI e quella delle immagini
    /// rendono il numero piu' bello e meno vero.
    @State private var hasMeasured = false
    /// Redesign 2.0: il calendario delle uscite si apre anche da qui. Il ViewModel legge lo
    /// stesso specchio locale di questa schermata (zero rete: §13.6 resta intatto) e si carica
    /// solo quando lo sheet compare — il primo fotogramma del Tracking non lo paga.
    @StateObject private var calendarViewModel = DiscoveryTrackingHighlightsViewModel()
    @State private var showReleaseCalendar = false
    /// Redesign 2.0: l'header globale è persistente su OGNI tab (prototipo). Disegna da stato
    /// locale (l'avatar arriva dalla cache immagini, differito): il budget §13.6 del primo
    /// frame non lo paga — la misura del probe resta dentro `content`.
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var showSearch = false
    @State private var showProfile = false

    var body: some View {
        VStack(spacing: 0) {
            AppHeaderView(
                onSearchTap: { showSearch = true },
                onProfileTap: { showProfile = true },
                avatarURL: appState.currentUser?.avatarURL,
                isProUser: quotaManager.isProUser
            )
            ScreenTitleHeader(
                title: "tab.tracking".localized,
                subtitle: "tracking.subtitle".localized,
                trailingIcon: "calendar",
                onTrailingTap: { showReleaseCalendar = true }
            )
            content
        }
            .background(Color.theme.backgroundDark.ignoresSafeArea())
            .sheet(isPresented: $showReleaseCalendar) {
                ReleaseCalendarView(viewModel: calendarViewModel)
            }
            .fullScreenCover(isPresented: $showSearch) {
                SearchView(viewModel: searchViewModel)
            }
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .task {
                let first = !hasMeasured
                hasMeasured = true
                await viewModel.load(measuring: first)
            }
            .alert(
                "tracking.error.title".localized,
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("common.ok".localized) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        // Senza la timeline a schermo, "vuoto" significa "nessun bucket": una cache che
        // avesse solo righe di timeline non è più contenuto di QUESTA schermata.
        if viewModel.sections.sections.isEmpty && !viewModel.isLoading {
            emptyState
        } else {
            List {
                // Il capolinea della misura: il primo fotogramma **con contenuto**. Si chiude un
                // turno di runloop dopo la comparsa, cioe' a layout calcolato e commit inviato.
                //
                // `if !isEmpty` non e' una precauzione, e' la misura stessa. La riga stava fuori
                // dalla condizione, e la sequenza era: `begin()`, `isLoading = true`, SwiftUI
                // ridisegna, la List compare **vuota** (i dati sono ancora dentro l'`await`),
                // questa riga appare e chiudeva il cronometro. Cioe' si misurava il tempo di
                // disegnare una lista vuota, e il numero sarebbe stato lusinghiero e falso anche
                // con dati veri — non solo sull'account senza storico a cui era stato attribuito.
                if !viewModel.sections.sections.isEmpty {
                    Color.clear.frame(height: 0)
                        .onAppear {
                            DispatchQueue.main.async { TrackingPerformanceProbe.firstFrameRendered() }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                // Redesign 2.0 (deciso dall'utente, 2026-08-03): le sezioni timeline
                // (Oggi/Domani/Questa settimana/Questo mese) NON si disegnano più qui — a
                // "cosa esce" risponde il calendario (icona in alto e strip in Scopri), che
                // legge le stesse righe di `tv_timeline`. Supera l'ordine di §9.2: due elenchi
                // delle stesse uscite in due forme erano il "due posti, due numeri" della UI.
                ForEach(viewModel.sections.sections, id: \.bucket) { bucket, rows in
                    Section(header: sectionHeader(bucket: bucket, count: rows.count)) {
                        if viewModel.isExpanded(bucket) {
                            ForEach(rows) { row in
                                TVTrackingCard(
                                    row: row,
                                    isBusy: busyShowId == row.showId,
                                    onMarkWatched: {
                                        perform(row) { try await TrackingActions.shared.markNextWatched(row) }
                                    },
                                    onSnooze: {
                                        perform(row) { try await TrackingActions.shared.snooze(row) }
                                    }
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await viewModel.load() }
        }
    }

    private func sectionHeader(bucket: TrackingBucket, count: Int) -> some View {
        Button { viewModel.toggle(bucket) } label: {
            HStack(spacing: 8) {
                Text(bucket.titleKey.localized)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                // Il conteggio sta nell'intestazione anche a sezione chiusa: §9.2 lo chiede, e
                // una sezione chiusa senza numero non dice se vale la pena aprirla.
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
                Spacer()
                // Un chevron solo, che ruota: lo stato aperto/chiuso si legge dal verso.
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
                    .rotationEffect(.degrees(viewModel.isExpanded(bucket) ? 0 : -90))
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isExpanded(bucket))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 44))
                .foregroundColor(.theme.textSecondary)
            Text("tracking.empty.title".localized)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            Text("tracking.empty.subtitle".localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// L'azione si accoda, il server ricalcola, si ritira, poi la schermata si rilegge. L'errore
    /// si mostra invece di sparire: una mutazione persa qui è una serie che non avanza, e l'utente
    /// non ha modo di accorgersene.
    private func perform(_ row: TrackingRow, _ action: @escaping () async throws -> Void) {
        guard busyShowId == nil else { return }
        busyShowId = row.showId
        Task {
            defer { busyShowId = nil }
            do {
                try await action()
                await viewModel.load()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// `TimelineRowView` non esiste più: le uscite si guardano nel calendario
// (`ReleaseCalendarView`), che ha la sua riga con poster, chip SxE e badge SPECIAL.
