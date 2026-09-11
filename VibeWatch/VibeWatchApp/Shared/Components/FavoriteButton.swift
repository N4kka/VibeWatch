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

/// La riga dei preferiti sotto il voto: una card, non un bottone testuale.
///
/// Prima era montata in un ramo morto di `TVShowDetailView` — la funzione esisteva e nessuno
/// poteva raggiungerla. Ora vive in entrambi i dettagli, dice quanti slot sono occupati e cosa
/// significa esserci ("in vetrina sul tuo profilo").
struct FavoriteButton: View {
    @StateObject private var viewModel: FavoriteButtonViewModel
    @State private var showSlotDialog = false

    /// Incorporata nella card condivisa col voto: niente sfondo proprio.
    private let isEmbedded: Bool

    init(mediaType: String, tmdbId: Int, isEmbedded: Bool = false) {
        _viewModel = StateObject(wrappedValue: FavoriteButtonViewModel(mediaType: mediaType, tmdbId: tmdbId))
        self.isEmbedded = isEmbedded
    }

    init(viewModel: FavoriteButtonViewModel, isEmbedded: Bool = false) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.isEmbedded = isEmbedded
    }

    private var isFavorite: Bool { viewModel.currentSlot != nil }

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                content
                    .background(Color.white.opacity(0.065))
                    .clipShape(RoundedRectangle(cornerRadius: 17))
            }
        }
        .task { await viewModel.load() }
        .confirmationDialog("favorites.add".localized, isPresented: $showSlotDialog) {
            // 4 slot espliciti (§3.6): il pallino segna quelli gia' occupati — sceglierne uno
            // occupato sostituisce, e va detto prima del tap, non scoperto dopo.
            ForEach(1...4, id: \.self) { slot in
                Button(String(format: "favorites.slot".localized, slot)
                       + (viewModel.occupiedSlots.contains(slot) ? " ●" : "")) {
                    Task {
                        let toastId = ToastCenter.shared.begin(message: "favorites.adding".localized)
                        await viewModel.setSlot(slot)
                        announce(toastId, added: true)
                    }
                }
            }
            if viewModel.currentSlot != nil {
                Button("favorites.remove".localized, role: .destructive) {
                    Task {
                        let toastId = ToastCenter.shared.begin(message: "favorites.removing".localized)
                        await viewModel.remove()
                        announce(toastId, added: false)
                    }
                }
            }
        }
    }

    private var content: some View {
        Button {
            showSlotDialog = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 13) {
                    icon

                    VStack(alignment: .leading, spacing: 2) {
                        Text((isFavorite ? "favorites.inYourFavorites" : "favorites.add").localized)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isFavorite ? .theme.accentOrange : .theme.textPrimary)

                        Text((isFavorite ? "favorites.showcased" : "favorites.subtitle").localized)
                            .font(.system(size: 13.5))
                            .foregroundColor(.theme.textSecondary)
                    }

                    Spacer(minLength: 8)

                    slotBadge
                }

                if viewModel.saveFailed {
                    Text("favorites.saveFailed".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 68)
            .background(isFavorite ? Color.theme.accentOrange.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSaving)
    }

    @ViewBuilder
    private var icon: some View {
        if viewModel.isSaving {
            ProgressView().scaleEffect(0.8).frame(width: 22)
        } else {
            Image(systemName: isFavorite ? "rosette" : "heart")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(isFavorite ? .theme.accentOrange : .theme.textSecondary)
                .frame(width: 22)
        }
    }

    private var slotBadge: some View {
        Text("\(viewModel.occupiedSlots.count)/4")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.theme.accentOrange)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isFavorite
                               ? Color.theme.accentOrange.opacity(0.18)
                               : Color.white.opacity(0.07))
            )
    }

    private func announce(_ toastId: String, added: Bool) {
        guard !viewModel.saveFailed else {
            ToastCenter.shared.fail(toastId, message: "favorites.saveFailed".localized)
            return
        }
        ToastCenter.shared.complete(
            toastId,
            message: (added ? "favorites.addedToast" : "favorites.removedToast").localized
        )
    }
}

/// Voto e preferiti sono la stessa decisione in due passi ("quanto mi è piaciuto" / "è uno dei
/// miei quattro"): stanno in una card sola, separati da una riga.
struct MediaRatingFavoriteCard: View {
    let mediaType: String
    let tmdbId: Int
    /// Identità del titolo per la card condivisibile del voto (social feed M1): senza,
    /// la sezione stelle funziona come sempre ma non offre lo share.
    var title: String? = nil
    var posterPath: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            StarRatingSection(mediaType: mediaType, tmdbId: tmdbId, isEmbedded: true,
                              title: title, posterPath: posterPath)

            Divider()
                .overlay(Color.white.opacity(0.08))

            FavoriteButton(mediaType: mediaType, tmdbId: tmdbId, isEmbedded: true)
        }
        // Niente `clipShape`: la capsula del voto sporge sopra il bordo mentre si trascina e
        // un ritaglio la trancerebbe. Lo sfondo arrotondato basta a dare la forma della card.
        .background(
            RoundedRectangle(cornerRadius: 17)
                .fill(Color.white.opacity(0.065))
        )
    }
}
