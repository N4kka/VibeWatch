import SwiftUI

/// SPEC v3 §3.6/§9.3 — mettere un titolo nei 4 slot dei preferiti, dal dettaglio film/serie.
///
/// Lo slot si sceglie, non si assegna: l'ordine conta (§3.6), e mettere un titolo in uno slot
/// occupato lo sostituisce — è la semantica della PK, qui come sul server. Lo stato attuale si
/// legge dallo specchio locale, zero rete; la scrittura passa da `FavoritesActions` (identità,
/// forma, rilettura), e un errore riporta lo stato vero e si dichiara.
@MainActor
final class FavoriteButtonViewModel: ObservableObject {
    @Published private(set) var occupiedSlots: Set<Int> = []
    @Published private(set) var currentSlot: Int?
    @Published private(set) var isSaving = false
    @Published private(set) var saveFailed = false

    private let mediaType: String
    private let tmdbId: Int
    private let actions: FavoritesActions
    private let sqlite: SQLiteService
    private let currentUserId: @MainActor () -> String?

    init(mediaType: String, tmdbId: Int,
         actions: FavoritesActions = .shared,
         sqlite: SQLiteService = .shared,
         currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.actions = actions
        self.sqlite = sqlite
        self.currentUserId = currentUserId
    }

    func load() async {
        guard let userId = currentUserId() else { return }
        do {
            let rows = try await sqlite.queryRaw(
                """
                SELECT slot, tmdb_id FROM user_favorites
                WHERE user_id = ? AND media_type = ? AND deleted_at IS NULL
                """,
                parameters: [userId, mediaType])
            var occupied: Set<Int> = []
            var mine: Int?
            for row in rows {
                let slot = (row["slot"] as? Int64).map(Int.init) ?? row["slot"] as? Int
                let id = (row["tmdb_id"] as? Int64).map(Int.init) ?? row["tmdb_id"] as? Int
                guard let slot else { continue }
                occupied.insert(slot)
                if id == tmdbId { mine = slot }
            }
            occupiedSlots = occupied
            currentSlot = mine
        } catch {
            // Come per le stelle: senza dato si parte vuoti, il primo tap scrive comunque.
        }
    }

    func setSlot(_ slot: Int) async {
        guard !isSaving else { return }
        let previousSlot = currentSlot
        let previousOccupied = occupiedSlots

        isSaving = true
        saveFailed = false
        currentSlot = slot
        occupiedSlots.insert(slot)
        defer { isSaving = false }

        do {
            try await actions.setFavorite(mediaType: mediaType, slot: slot, tmdbId: tmdbId)
        } catch {
            currentSlot = previousSlot
            occupiedSlots = previousOccupied
            saveFailed = true
        }
    }

    func remove() async {
        guard !isSaving, let slot = currentSlot else { return }
        let previousOccupied = occupiedSlots

        isSaving = true
        saveFailed = false
        currentSlot = nil
        occupiedSlots.remove(slot)
        defer { isSaving = false }

        do {
            try await actions.clearFavorite(mediaType: mediaType, slot: slot)
        } catch {
            currentSlot = slot
            occupiedSlots = previousOccupied
            saveFailed = true
        }
    }
}

struct FavoriteButton: View {
    @StateObject private var viewModel: FavoriteButtonViewModel
    @State private var showSlotDialog = false

    init(mediaType: String, tmdbId: Int) {
        _viewModel = StateObject(wrappedValue: FavoriteButtonViewModel(mediaType: mediaType, tmdbId: tmdbId))
    }

    init(viewModel: FavoriteButtonViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                showSlotDialog = true
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: viewModel.currentSlot == nil ? "trophy" : "trophy.fill")
                    }
                    Text((viewModel.currentSlot == nil ? "favorites.add" : "favorites.remove").localized)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.theme.accentOrange)
            }
            .disabled(viewModel.isSaving)

            if viewModel.saveFailed {
                Text("favorites.saveFailed".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .task { await viewModel.load() }
        .confirmationDialog("favorites.add".localized, isPresented: $showSlotDialog) {
            // 4 slot espliciti (§3.6): il pallino segna quelli gia' occupati — sceglierne uno
            // occupato sostituisce, e va detto prima del tap, non scoperto dopo.
            ForEach(1...4, id: \.self) { slot in
                Button(String(format: "favorites.slot".localized, slot)
                       + (viewModel.occupiedSlots.contains(slot) ? " ●" : "")) {
                    Task { await viewModel.setSlot(slot) }
                }
            }
            if viewModel.currentSlot != nil {
                Button("favorites.remove".localized, role: .destructive) {
                    Task { await viewModel.remove() }
                }
            }
        }
    }
}
