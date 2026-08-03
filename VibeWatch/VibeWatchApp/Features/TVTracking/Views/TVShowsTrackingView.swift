import SwiftUI

/// SPEC v3 §9.2 — la schermata che l'utente TV Time apre ogni giorno.
///
/// L'ordine delle sezioni è quello della spec e non una scelta estetica: "Da guardare" in cima
/// perché è il motivo per cui la schermata esiste, la timeline subito sotto perché risponde alla
/// seconda domanda ("cosa esce"), il resto chiuso di default perché sono elenchi lunghi che non
/// servono ogni giorno.
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

    var body: some View {
        VStack(spacing: 0) {
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
        if viewModel.sections.isEmpty && !viewModel.isLoading {
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
                if !viewModel.sections.isEmpty {
                    Color.clear.frame(height: 0)
                        .onAppear {
                            DispatchQueue.main.async { TrackingPerformanceProbe.firstFrameRendered() }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                ForEach(viewModel.sections.timeline, id: \.group) { group, entries in
                    Section(header: Text(group.titleKey.localized)) {
                        ForEach(entries) { entry in
                            TimelineRowView(entry: entry)
                        }
                    }
                }

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

/// Una riga della timeline: cosa esce, quando.
private struct TimelineRowView: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.label)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.showName ?? "tracking.unknownShow".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                if let name = entry.episodeName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // §1.3: gli speciali si marcano, non si filtrano. Qui il marchio è letterale.
            if entry.isSpecial {
                Text("tracking.special".localized)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }

            // §3.3, limite noto: TMDB dà il giorno, non l'ora. Si mostra il giorno e basta —
            // inventare "02:00" perché TV Time lo mostrava significherebbe inventare un dato che
            // non abbiamo, ed è l'imprecisione che l'utente nota subito.
            Text(entry.airDate, format: .dateTime.day().month(.abbreviated))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.theme.textSecondary)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
