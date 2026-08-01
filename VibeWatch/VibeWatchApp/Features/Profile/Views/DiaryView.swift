import SwiftUI

/// SPEC v3 §9.3 — il diario: eventi in ordine cronologico inverso, con la data di visione reale.
///
/// Tre stati distinti e mai schiacciati (la regola di tutta la famiglia): caricamento, righe
/// (o "vuoto", che e' una risposta vera), e **lettura fallita** — un errore non si traveste da
/// "non hai visto niente". Le pagine sono da 100: un import TV Time porta ~1.600 eventi nella
/// finestra di 12 mesi, e caricarli tutti in un colpo per una schermata che si scorre e' spreco.
@MainActor
final class DiaryViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded([DiaryEntry], hasMore: Bool)
        case empty
        case failed
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var movieTitles: [Int: String] = [:]
    @Published private(set) var showTitles: [Int: String] = [:]

    static let pageSize = 100

    private let fetchPage: (Int, Int) async throws -> [DiaryEntry]
    private let resolveMovieTitle: (Int) async -> String?
    private let resolveShowTitle: (Int) async -> String?
    private var isLoadingMore = false

    init(fetchPage: @escaping (Int, Int) async throws -> [DiaryEntry] =
            { try await LocalDiaryRepository.shared.page(limit: $0, offset: $1) },
         resolveMovieTitle: @escaping (Int) async -> String? =
            { try? await TMDBService.shared.getMovieDetails(id: $0).title },
         resolveShowTitle: @escaping (Int) async -> String? =
            { try? await TMDBService.shared.getTVShowDetails(id: $0).name }) {
        self.fetchPage = fetchPage
        self.resolveMovieTitle = resolveMovieTitle
        self.resolveShowTitle = resolveShowTitle
    }

    func load() async {
        phase = .loading
        do {
            let entries = try await fetchPage(Self.pageSize, 0)
            phase = entries.isEmpty
                ? .empty
                : .loaded(entries, hasMore: entries.count == Self.pageSize)
            await resolveMissingTitles(in: entries)
        } catch {
            phase = .failed
        }
    }

    func loadMoreIfNeeded(current entry: DiaryEntry) async {
        guard case .loaded(let entries, true) = phase,
              entry.id == entries.last?.id, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await fetchPage(Self.pageSize, entries.count)
            phase = .loaded(entries + more, hasMore: more.count == Self.pageSize)
            await resolveMissingTitles(in: more)
        } catch {
            // La pagina successiva che fallisce non butta via quelle gia' mostrate: si riprova
            // al prossimo scroll. Le righe a schermo restano vere.
        }
    }

    /// I film non hanno un nome nello specchio locale (un catalogo film non esiste, §9.3): si
    /// risolve dal client, una volta per id, meglio tardi che sbagliato.
    ///
    /// Anche le serie passano di qui, per un motivo diverso: lo specchio ha un nome, ma è quello
    /// del **catalogo condiviso** (§1.5), che parla una lingua sola — in pratica l'inglese di
    /// TMDB. TMDBService invece chiede nella lingua dell'app. Il nome dello specchio resta il
    /// ripiego: offline si vede il titolo inglese, che è vero, non un buco.
    private func resolveMissingTitles(in entries: [DiaryEntry]) async {
        let movieIds = Set(entries.filter { $0.mediaType == "movie" }.map(\.tmdbId))
            .subtracting(movieTitles.keys)
        for id in movieIds {
            if let title = await resolveMovieTitle(id) {
                movieTitles[id] = title
            }
        }
        let showIds = Set(entries.filter { $0.mediaType == "tv" }.map(\.tmdbId))
            .subtracting(showTitles.keys)
        for id in showIds {
            if let title = await resolveShowTitle(id) {
                showTitles[id] = title
            }
        }
    }
}

struct DiaryView: View {
    @StateObject private var viewModel: DiaryViewModel
    @Environment(\.dismiss) private var dismiss

    init() {
        _viewModel = StateObject(wrappedValue: DiaryViewModel())
    }

    init(viewModel: DiaryViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("diary.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Lo sheet si chiude anche con lo swipe, ma una stanza merita una porta visibile
            // (lezione del pannello AI del blocco 7). Stesso pattern di UserSearchView.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("profile.done".localized) { dismiss() }
                    .foregroundColor(.theme.textPrimary)
            }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "book")
                    .font(.system(size: 34))
                    .foregroundColor(.theme.textSecondary.opacity(0.6))
                Text("diary.empty".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
        case .failed:
            VStack(spacing: 12) {
                Text("diary.loadFailed".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                Button("common.retry".localized) {
                    Task { await viewModel.load() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
        case .loaded(let entries, _):
            List {
                ForEach(entries) { entry in
                    row(entry)
                        .listRowBackground(Color.clear)
                        .task { await viewModel.loadMoreIfNeeded(current: entry) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ entry: DiaryEntry) -> some View {
        HStack(spacing: 12) {
            poster(entry)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: entry))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                if let label = entry.episodeLabel {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            Spacer()
            // §3.2: una data dedotta (import in blocco, migrazione) si mostra come circa,
            // non spacciata per il giorno esatto in cui l'utente ha premuto "visto".
            Text((entry.isInferred ? "≈ " : "") + Self.dateFormatter.string(from: entry.watchedAt))
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func title(for entry: DiaryEntry) -> String {
        if entry.mediaType == "movie" {
            return viewModel.movieTitles[entry.tmdbId] ?? "···"
        }
        // Prima il titolo nella lingua dell'app; il nome del catalogo (inglese) fa da ripiego
        // per l'offline. Un titolo vero in una lingua sbagliata batte un buco.
        return viewModel.showTitles[entry.tmdbId] ?? entry.title ?? "···"
    }

    private func poster(_ entry: DiaryEntry) -> some View {
        Group {
            if let path = entry.posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w154\(path)") {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    posterPlaceholder(entry)
                }
            } else {
                posterPlaceholder(entry)
            }
        }
        .frame(width: 36, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func posterPlaceholder(_ entry: DiaryEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
            Image(systemName: entry.mediaType == "movie" ? "film" : "tv")
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
        }
    }
}
