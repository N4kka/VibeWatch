import SwiftUI

/// Il momento del consenso al feed, una volta sola: spiega cosa diventa visibile (compreso il
/// PASSATO — visioni, voti e liste già registrati) e chiede una scelta esplicita. Nessun dark
/// pattern: il "no" è un bottone normale, non una scritta grigia nascosta, e finché non si
/// risponde le attività dell'utente NON compaiono nel feed altrui (gate lato server).
struct FeedAnnouncementView: View {
    /// Chiamata quando l'utente HA risposto (in un senso o nell'altro): il chiamante
    /// persiste il "già chiesto" e chiude lo sheet.
    var onAnswered: () -> Void
    /// Chiusura senza risposta (la X): si ripresenterà — la domanda resta aperta.
    var onClose: () -> Void

    var repository: ActivityFeedProviding?

    /// Opt-in separato e spento di default: rendere pubbliche le liste è un passo in più
    /// rispetto al feed, non un sottinteso.
    @State private var makeListsPublic = false
    @State private var isSaving = false

    var body: some View {
        VWModalSheet(
            title: "social.announcement.title".localized,
            onClose: { if !isSaving { onClose() } },
            primaryTitle: "social.announcement.confirm".localized,
            primaryEnabled: !isSaving,
            primaryAction: { answer(enabled: true) },
            secondaryTitle: "social.announcement.decline".localized,
            secondaryAction: { if !isSaving { answer(enabled: false) } }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                paragraph("social.announcement.body1")
                paragraph("social.announcement.body2")
                paragraph("social.announcement.body3")

                listsCheckbox
                    .padding(.top, 6)
            }
        }
        .vwModalPresentation()
    }

    private func paragraph(_ key: String) -> some View {
        Text(key.localized)
            .font(.system(size: 15))
            .foregroundColor(.theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var listsCheckbox: some View {
        Button {
            makeListsPublic.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: makeListsPublic ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(makeListsPublic ? .theme.accentOrange : .theme.textSecondary)

                Text("social.announcement.listsToggle".localized)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isSaving)
    }

    // MARK: - Risposta

    /// Una risposta, qualunque sia, timbra il consenso sul server (`feed_activated_at`).
    /// Solo a scrittura riuscita si aggiorna lo specchio locale e si chiude: un fallimento
    /// lascia la domanda aperta invece di fingere che sia stata registrata.
    private func answer(enabled: Bool) {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            let repo = repository ?? ActivityFeedRepository()
            do {
                try await repo.setActivityFeedVisibility(enabled)

                // Le liste pubbliche solo se richiesto E se il feed è stato acceso: rendere
                // pubbliche le liste di chi ha appena detto "resto privato" sarebbe un tradimento.
                if enabled && makeListsPublic {
                    await publishCustomLists()
                }

                await stampLocalMirror(enabled: enabled)
                ToastCenter.shared.show(success: (enabled
                    ? "social.announcement.toast.enabled"
                    : "social.announcement.toast.disabled").localized)
                isSaving = false
                onAnswered()
            } catch {
                Logger.warning("[FeedAnnouncement] Failed to save consent: \(error.localizedDescription)")
                ToastCenter.shared.show(error: "social.announcement.toast.failed".localized)
                isSaving = false
            }
        }
    }

    /// Pubblica le custom private via ListManager (mirror + outbox). Best-effort per lista:
    /// una lista che non si pubblica non deve annullare il consenso già registrato.
    @MainActor
    private func publishCustomLists() async {
        let manager = ListManager.shared
        for list in manager.lists where list.type == .custom && !list.isPublic {
            do {
                try await manager.setListVisibility(listId: list.id, isPublic: true)
            } catch {
                Logger.warning("[FeedAnnouncement] Failed to publish list \(list.id): \(error.localizedDescription)")
            }
        }
    }

    /// Aggiorna lo specchio `profiles` senza aspettare il prossimo pull: è ciò che SocialView
    /// e Settings leggono per sapere che la domanda è stata già posta. Se la riga locale non
    /// esiste ancora, pazienza — il flag @AppStorage copre la sessione e il pull farà il resto.
    @MainActor
    private func stampLocalMirror(enabled: Bool) async {
        guard let userId = SupabaseService.shared.currentUser?.id else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try? await SQLiteService.shared.executeWrite(
            "UPDATE profiles SET activity_feed_enabled = ?, feed_activated_at = ? WHERE id = ?",
            parameters: [enabled ? 1 : 0, now, userId])
    }
}

#Preview("Annuncio feed") {
    Color.theme.background
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            FeedAnnouncementView(onAnswered: {}, onClose: {})
                .interactiveDismissDisabled()
        }
}
