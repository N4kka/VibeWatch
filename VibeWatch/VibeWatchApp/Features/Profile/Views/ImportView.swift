import SwiftUI
import UniformTypeIdentifiers

/// SPEC v3 §7 — "Import from". Oggi una sorgente sola, TV Time (.zip), ma la schermata è una
/// lista apposta: gli import futuri sono righe nuove, non schermate nuove.
///
/// La vista è un oblò sul job (§7.2: lo stato vive sul server, le fasi le muove il cron):
/// l'unico tratto che richiede l'app aperta è l'upload. Appena il job esiste lo si dice
/// esplicitamente — "puoi chiudere l'app" — perché è la promessa della spec, non un dettaglio.
@MainActor
struct ImportView: View {
    @StateObject private var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    init(viewModel: ImportViewModel? = nil) {
        // Il default sta QUI e non nella firma: un default argument è nonisolated, e il
        // ViewModel è @MainActor.
        _viewModel = StateObject(wrappedValue: viewModel ?? ImportViewModel())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("import.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel(Text("common.close".localized))
                }
            }
            .task { await viewModel.loadExisting() }
            .onDisappear { viewModel.stopPolling() }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result {
                    Task { await viewModel.importFile(at: url) }
                }
                // Il picker annullato non è un errore: si resta sulle sorgenti.
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .sources:
            sourcesList
        case .uploading:
            statusPanel(icon: nil, titleKey: "import.state.uploading",
                        subtitleKey: "import.state.uploadingHint", spinning: true)
        case .running(_, let phase):
            statusPanel(icon: nil, titleKey: phaseKey(phase),
                        subtitleKey: "import.canClose", spinning: true)
        case .done(let report):
            reportView(report)
        case .failed(let messageKey, let detail, _):
            failedView(messageKey: messageKey, detail: detail)
        }
    }

    // MARK: - Sorgenti

    private var sourcesList: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 20))
                            .foregroundColor(.theme.accentOrange)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("import.source.tvtime".localized)
                                .font(.system(size: 16))
                                .foregroundColor(.theme.textPrimary)
                            Text("import.source.tvtime.subtitle".localized)
                                .font(.system(size: 13))
                                .foregroundColor(.theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.white.opacity(0.05))
            } footer: {
                Text("import.source.footer".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Stato in corso

    private func statusPanel(icon: String?, titleKey: String, subtitleKey: String,
                             spinning: Bool) -> some View {
        VStack(spacing: 14) {
            if spinning {
                ProgressView().controlSize(.large)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(.theme.textSecondary)
            }
            Text(titleKey.localized)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            Text(subtitleKey.localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func phaseKey(_ phase: String) -> String {
        switch phase {
        case "uploaded":    return "import.phase.queued"
        case "parsing":     return "import.phase.parsing"
        case "resolving":   return "import.phase.resolving"
        case "writing":     return "import.phase.writing"
        case "recomputing": return "import.phase.finishing"
        default:            return "import.phase.queued"
        }
    }

    // MARK: - Report (§7.4)

    private func reportView(_ report: ImportReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    reportNumber(report.episodiImportati, key: "import.report.episodes")
                    reportNumber(report.serieImportate, key: "import.report.shows")
                }
                .frame(maxWidth: .infinity)

                if let dal = report.dal.flatMap(Self.shortDate),
                   let al = report.al.flatMap(Self.shortDate) {
                    Text(String(format: "import.report.period".localized, dal, al))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // §7.1: gli stati per-serie ripristinati (watchlist e archivio). Solo per i job
                // che li supportano: su un report vecchio l'assenza non è uno zero.
                if report.statiSupportati && report.statiSerieImportati > 0 {
                    Text(String(format: "import.report.statusesApplied".localized,
                                report.statiSerieImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.statiSupportati && report.statiSerieNonRisolti > 0 {
                    Text(String(format: "import.report.statusesUnresolved".localized,
                                report.statiSerieNonRisolti))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // §7.5: i voti. Su un job nuovo le stelle sono in `user_ratings` e si contano
                // (comprese quelle lasciate al voto già dato in app: non è una perdita); su un
                // job vecchio resta la riga "non ancora importati" — uno zero muto sarebbe
                // indistinguibile da "non ne avevi".
                if report.votiImportati && report.votiStelleImportati > 0 {
                    Text(String(format: "import.report.ratingsApplied".localized,
                                report.votiStelleImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.votiImportati && report.votiStelleNonRisolti > 0 {
                    Text(String(format: "import.report.ratingsUnresolved".localized,
                                report.votiStelleNonRisolti))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.votiStelle + report.votiReaction > 0 && !report.votiImportati {
                    Text(String(format: "import.report.ratingsDeferred".localized,
                                report.votiStelle + report.votiReaction))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // §7.4: "N elementi non riconosciuti, con l'elenco dei titoli". Senza abbellire.
                if report.nonRiconosciutiEpisodi > 0 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(format: "import.report.unresolvedTitle".localized,
                                    report.nonRiconosciutiEpisodi))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                        ForEach(report.nonRiconosciutiElenco, id: \.titolo) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.titolo)
                                    .font(.system(size: 14))
                                    .foregroundColor(.theme.textPrimary)
                                Text(String(format: "import.report.unresolvedRow".localized,
                                            item.episodi) + " · " + item.motivo)
                                    .font(.system(size: 12))
                                    .foregroundColor(.theme.textSecondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05)))
                } else {
                    Text("import.report.allResolved".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Button("common.done".localized) { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding()
        }
    }

    private func reportNumber(_ value: Int, key: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            Text(key.localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    /// Le date del report sono timestamp ISO del server: qui si mostra solo il giorno.
    private static func shortDate(_ iso: String) -> String? {
        String(iso.prefix(10)).isEmpty ? nil : String(iso.prefix(10))
    }

    // MARK: - Fallito

    private func failedView(messageKey: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.theme.textSecondary)
            Text(messageKey.localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                // La verità tecnica, piccola ma visibile: §7.4 vieta di abbellire.
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button("common.retry".localized) {
                Task { await viewModel.retry() }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.theme.accentOrange)
            .padding(.top, 4)
        }
        .padding()
    }
}
