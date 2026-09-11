import SwiftUI

/// La sezione "Social" delle impostazioni: il toggle di visibilità nel feed attività.
///
/// Autocontenuta di proposito (stato, lettura dello specchio, scrittura remota): SettingsView
/// la incorpora con una riga e non deve sapere niente di RPC o specchio profili. Il toggle è
/// ottimistico con rollback: lo stato sullo schermo torna quello vero se il server non ha
/// mai saputo del cambio — la stessa regola imparata con StarRatingSection.
struct SocialSettingsSection: View {
    var repository: ActivityFeedProviding?

    @State private var feedEnabled = false
    @State private var isLoaded = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 16) {
            Text("social.settings.title".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)

            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.theme.accentOrange.opacity(0.2))
                        .frame(width: 44, height: 44)

                    Image(systemName: "person.2.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.theme.accentOrange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("social.settings.showActivity".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)

                    Text("social.settings.showActivity.description".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Binding esplicito invece di onChange: il set parte SOLO da un gesto
                // dell'utente, mai dal caricamento iniziale del valore dallo specchio.
                Toggle("", isOn: Binding(
                    get: { feedEnabled },
                    set: { newValue in updateVisibility(newValue) }
                ))
                .labelsHidden()
                .tint(.theme.accentOrange)
                .disabled(!isLoaded || isSaving)
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .task { await loadCurrentValue() }
    }

    /// Il valore iniziale viene dallo specchio `profiles` (zero rete): il pull ci scrive
    /// `activity_feed_enabled` insieme al resto del profilo.
    @MainActor
    private func loadCurrentValue() async {
        guard !isLoaded, let userId = SupabaseService.shared.currentUser?.id else { return }
        let rows = (try? await SQLiteService.shared.queryRaw(
            "SELECT activity_feed_enabled FROM profiles WHERE id = ?",
            parameters: [userId])) ?? []
        if let raw = rows.first?["activity_feed_enabled"] {
            feedEnabled = (raw as? Int64).map { $0 != 0 }
                ?? (raw as? Int).map { $0 != 0 }
                ?? false
        }
        isLoaded = true
    }

    private func updateVisibility(_ newValue: Bool) {
        guard !isSaving else { return }
        let previous = feedEnabled
        feedEnabled = newValue // ottimistico
        isSaving = true

        Task { @MainActor in
            let repo = repository ?? ActivityFeedRepository()
            do {
                try await repo.setActivityFeedVisibility(newValue)
                // Specchio aggiornato subito: Settings e SocialView leggono da qui, e il
                // prossimo pull confermerà lo stesso valore dal server.
                if let userId = SupabaseService.shared.currentUser?.id {
                    try? await SQLiteService.shared.executeWrite(
                        "UPDATE profiles SET activity_feed_enabled = ? WHERE id = ?",
                        parameters: [newValue ? 1 : 0, userId])
                }
                ToastCenter.shared.show(success: (newValue
                    ? "social.announcement.toast.enabled"
                    : "social.announcement.toast.disabled").localized)
            } catch {
                // Rollback: un'impostazione che il server non ha mai registrato non resta
                // sullo schermo a mentire.
                feedEnabled = previous
                ToastCenter.shared.show(error: "social.settings.updateFailed".localized)
            }
            isSaving = false
        }
    }
}

#Preview("Sezione settings Social") {
    ZStack {
        Color.theme.background.ignoresSafeArea()
        SocialSettingsSection()
            .padding(20)
    }
}
