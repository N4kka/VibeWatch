import SwiftUI

/// I preferiti dell'utente, nel suo profilo.
///
/// Erano visibili solo sul profilo **altrui**: si potevano scegliere e poi non si vedevano più, e
/// per toglierne uno bisognava tornare sul dettaglio del titolo e indovinare quale slot occupava.
/// Qui stanno in vetrina, con la X che li toglie sul posto.
@MainActor
final class ProfileFavoritesViewModel: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let mediaType: String
        let slot: Int
        let tmdbId: Int

        var id: String { "\(mediaType):\(slot)" }
    }

    /// 4 slot per film + 4 per serie: la vetrina è una sola, il totale è otto.
    static let totalSlots = 8

    @Published private(set) var entries: [Entry] = []

    private let sqlite: SQLiteService
    private let actions: FavoritesActions
    private let currentUserId: @MainActor () -> String?

    init(
        sqlite: SQLiteService = .shared,
        actions: FavoritesActions = .shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }
    ) {
        self.sqlite = sqlite
        self.actions = actions
        self.currentUserId = currentUserId
    }

    func load() async {
        guard let userId = currentUserId() else {
            entries = []
            return
        }
        let rows = (try? await sqlite.queryRaw(
            """
            SELECT media_type, slot, tmdb_id FROM user_favorites
             WHERE user_id = ? AND deleted_at IS NULL
             ORDER BY media_type, slot
            """,
            parameters: [userId]
        )) ?? []

        entries = rows.compactMap { row in
            guard let mediaType = row["media_type"] as? String,
                  let slot = (row["slot"] as? Int64).map(Int.init) ?? row["slot"] as? Int,
                  let tmdbId = (row["tmdb_id"] as? Int64).map(Int.init) ?? row["tmdb_id"] as? Int
            else { return nil }
            return Entry(mediaType: mediaType, slot: slot, tmdbId: tmdbId)
        }
    }

    /// Rimozione diretta, senza popup: è reversibile in due tocchi dal dettaglio, e un popup di
    /// conferma per un gesto così leggero è solo un ostacolo.
    func remove(_ entry: Entry) async {
        let precedenti = entries
        entries.removeAll { $0.id == entry.id }
        let toastId = ToastCenter.shared.begin(message: "favorites.removing".localized)
        do {
            try await actions.clearFavorite(mediaType: entry.mediaType, slot: entry.slot)
            ToastCenter.shared.complete(toastId, message: "favorites.removedToast".localized)
        } catch {
            entries = precedenti
            ToastCenter.shared.fail(toastId, message: "favorites.saveFailed".localized)
        }
    }
}

struct ProfileFavoritesSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProfileFavoritesViewModel()
    var onSelect: (ProfileFavoritesViewModel.Entry) -> Void

    var body: some View {
        Group {
            // Nessun preferito: la sezione non esiste, invece di mostrare otto buchi.
            if !viewModel.entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    row
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
            }
        }
        .task { await viewModel.load() }
        // All'avvio a freddo il primo `.task` gira quando l'utente non è ancora risolto: senza
        // questo, la sezione resta vuota fino al primo sync completato.
        .onChange(of: appState.currentUser?.id) { _, _ in
            Task { await viewModel.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncEngineCompleted)) { _ in
            Task { await viewModel.load() }
        }
    }

    private var header: some View {
        HStack {
            Text("favorites.sectionTitle".localized.uppercased())
                .font(.system(size: 11.5, weight: .heavy))
                .tracking(1.1)
                .foregroundColor(.theme.textSecondary)
            Spacer()
            Text(String(format: "favorites.sectionCount".localized,
                        viewModel.entries.count, ProfileFavoritesViewModel.totalSlots))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(viewModel.entries) { entry in
                    tile(entry)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func tile(_ entry: ProfileFavoritesViewModel.Entry) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onSelect(entry)
            } label: {
                FavoritePosterTile(mediaType: entry.mediaType, tmdbId: entry.tmdbId)
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.remove(entry) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("favorites.remove".localized))
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}
