import SwiftUI

/// Impostazioni → Social → "Blocked users": chi ho bloccato, con lo sblocco per riga.
///
/// La verità è del server (`fetchBlockedUsers`): lo specchio locale conosce solo i blocchi
/// accodati da questo client, mentre `block_user` e `block_list_owner` scrivono direttamente
/// in produzione. Lo sblocco invece segue la strada client-synced (`ListManager.unblockUser`,
/// soft delete via outbox), quindi funziona anche offline: la riga sparisce subito e la
/// mutazione parte quando può.
struct BlockedUsersView: View {
    @Environment(\.dismiss) private var dismiss

    /// Tre stati e nessuna finzione, come le liste del profilo pubblico: un errore di rete non
    /// è "non hai bloccato nessuno" — travestirlo da vuoto inviterebbe a ribloccare qualcuno.
    private enum Phase: Equatable {
        case loading
        case loaded([SupabaseService.BlockedUser])
        case failed
    }

    @State private var phase: Phase = .loading
    /// Un'azione per volta e per riga: due tap sullo stesso "Unblock" accoderebbero due DELETE.
    @State private var unblockingIds: Set<String> = []

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("settings.blockedUsers.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        // Come NotificationPreferencesView: push da Impostazioni, che nasconde la barra propria
        // — la porta di ritorno va rimessa a mano.
        .navigationBarHidden(false)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                BackCircleButton { dismiss() }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed:
            VStack(spacing: 12) {
                stateMessage(icon: "wifi.exclamationmark",
                             textKey: "settings.blockedUsers.loadFailed")
                Button("common.retry".localized) {
                    phase = .loading
                    Task { await load() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
        case .loaded(let users):
            if users.isEmpty {
                stateMessage(icon: "hand.raised.slash",
                             textKey: "settings.blockedUsers.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(users) { entry in
                            row(entry)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    // MARK: - Righe

    private func row(_ entry: SupabaseService.BlockedUser) -> some View {
        HStack(spacing: 12) {
            avatar(entry.profile)

            VStack(alignment: .leading, spacing: 3) {
                // Un bloccato col profilo privato non ha identità pubblica: si dichiara
                // "profilo non disponibile" invece di inventare un nome — resta sbloccabile.
                Text(entry.profile?.displayName
                     ?? entry.profile?.username
                     ?? "settings.blockedUsers.unavailableProfile".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                if let username = entry.profile?.username {
                    Text("@\(username)")
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            unblockButton(entry)
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func unblockButton(_ entry: SupabaseService.BlockedUser) -> some View {
        Button {
            Task { await unblock(entry) }
        } label: {
            Group {
                if unblockingIds.contains(entry.blockId) {
                    ProgressView().tint(.theme.textPrimary)
                } else {
                    Text("social.unblock".localized)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(minWidth: 76)
            .frame(height: 32)
            .foregroundColor(.theme.textPrimary)
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
        .disabled(unblockingIds.contains(entry.blockId))
    }

    private func avatar(_ profile: PublicProfile?) -> some View {
        Group {
            if let urlString = profile?.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder(profile)
                }
            } else {
                avatarPlaceholder(profile)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private func avatarPlaceholder(_ profile: PublicProfile?) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            if let initial = profile?.username.first {
                Text(String(initial).uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
            } else {
                Image(systemName: "person.slash")
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }

    private func stateMessage(icon: String, textKey: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
            Text(textKey.localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Azioni

    private func load() async {
        do {
            phase = .loaded(try await SupabaseService.shared.fetchBlockedUsers())
        } catch {
            phase = .failed
        }
    }

    private func unblock(_ entry: SupabaseService.BlockedUser) async {
        guard !unblockingIds.contains(entry.blockId) else { return }
        unblockingIds.insert(entry.blockId)
        defer { unblockingIds.remove(entry.blockId) }
        do {
            try await ListManager.shared.unblockUser(blockId: entry.blockId)
            // La riga sparisce solo DOPO l'accodamento riuscito: un tap che toglie la riga e
            // poi fallisce in silenzio lascerebbe un blocco vivo con la faccia di uno sbloccato.
            if case .loaded(let current) = phase {
                phase = .loaded(current.filter { $0.blockId != entry.blockId })
            }
            ToastCenter.shared.show(success: "social.unblock.done".localized)
        } catch {
            ToastCenter.shared.show(error: "common.error".localized)
        }
    }
}
