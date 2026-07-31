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

    var body: some View {
        content
            .background(Color.theme.backgroundDark.ignoresSafeArea())
            .task { await viewModel.load() }
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
                                    onMarkWatched: {
                                        perform { try await TrackingActions.shared.markNextWatched(row) }
                                    },
                                    onSnooze: {
                                        perform { try await TrackingActions.shared.snooze(row) }
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                // Il conteggio sta nell'intestazione anche a sezione chiusa: §9.2 lo chiede, e
                // una sezione chiusa senza numero non dice se vale la pena aprirla.
                Text("\(count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.theme.textSecondary)
                Spacer()
                Image(systemName: viewModel.isExpanded(bucket) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
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

    /// L'azione si accoda, poi la schermata si rilegge. L'errore si mostra invece di sparire: una
    /// mutazione persa qui è una serie che non avanza, e l'utente non ha modo di accorgersene.
    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
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
