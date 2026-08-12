import SwiftUI

/// Social feed M1 — la one-liner alla Letterboxd: una frase, 280 caratteri, spoiler dichiarati.
///
/// È un `VWModalSheet` come le altre modali di input: editor multilinea con contatore vivo,
/// toggle spoiler, riga di eliminazione quando si sta riscrivendo una review esistente. La
/// validazione visibile qui (1...280 sul contenuto trimmato) è la stessa di `ReviewActions`,
/// che a sua volta specchia il CHECK del server: il bottone si spegne dove l'errore si vede,
/// invece di lasciare che il salvataggio muoia in `sync_rejected_mutations`.
struct ReviewComposerView: View {
    let mediaType: String
    let tmdbId: Int
    let existingReview: ReviewActions.LocalReview?
    /// Il chiamante rilegge lo specchio locale e, se vuole, offre il momento di condivisione.
    var onSaved: () -> Void
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var containsSpoilers: Bool
    @State private var isWorking = false
    @State private var showDeleteConfirm = false

    init(mediaType: String, tmdbId: Int,
         existingReview: ReviewActions.LocalReview? = nil,
         onSaved: @escaping () -> Void = {},
         onDeleted: @escaping () -> Void = {}) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.existingReview = existingReview
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _content = State(initialValue: existingReview?.content ?? "")
        _containsSpoilers = State(initialValue: existingReview?.containsSpoilers ?? false)
    }

    /// Il conteggio che conta è quello trimmato: è ciò che il CHECK del server misura, e un
    /// contatore che dicesse 281 per uno spazio in coda spegnerebbe il bottone senza ragione.
    private var trimmedCount: Int {
        content.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSave: Bool {
        (1...ReviewActions.maxContentLength).contains(trimmedCount)
    }

    /// Il contatore cambia colore prima del muro, non solo dopo: arancione quando il limite
    /// si avvicina, rosso quando è superato (l'eccesso non si tronca: si vede e si accorcia).
    private var counterColor: Color {
        if trimmedCount > ReviewActions.maxContentLength { return .red }
        if trimmedCount >= ReviewActions.maxContentLength - 20 { return .theme.accentOrange }
        return .theme.textSecondary
    }

    var body: some View {
        VWModalSheet(
            title: (existingReview == nil
                    ? "review.composer.title" : "review.composer.editTitle").localized,
            subtitle: "review.composer.subtitle".localized,
            onClose: { dismiss() },
            primaryTitle: "common.save".localized,
            primaryEnabled: canSave && !isWorking,
            primaryAction: { Task { await save() } },
            secondaryTitle: "common.cancel".localized,
            secondaryAction: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                editor
                spoilerCard

                if existingReview != nil {
                    deleteRow
                }
            }
        }
        .vwModalPresentation()
        .sheet(isPresented: $showDeleteConfirm) {
            VWConfirmationSheet(
                title: "review.delete.confirmTitle".localized,
                message: "review.delete.confirmMessage".localized,
                confirmTitle: "common.delete".localized,
                isDestructive: true,
                onConfirm: {
                    showDeleteConfirm = false
                    Task { await deleteReview() }
                },
                onCancel: { showDeleteConfirm = false }
            )
            .vwModalPresentation()
        }
    }

    /// Lo stesso editor delle modali di feedback: TextEditor su card, contatore sotto la riga.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if content.isEmpty {
                    Text("review.composer.placeholder".localized)
                        .font(.system(size: 16))
                        .foregroundColor(.theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                }

                TextEditor(text: $content)
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .foregroundColor(.theme.textPrimary)
            }

            Divider().overlay(Color.white.opacity(0.1))

            HStack {
                Spacer()
                Text("\(trimmedCount)/\(ReviewActions.maxContentLength)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(counterColor)
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var spoilerCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("review.composer.spoilers".localized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text("review.composer.spoilersHint".localized)
                    .font(.system(size: 13.5))
                    .foregroundColor(.theme.textSecondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $containsSpoilers)
                .labelsHidden()
                .tint(.theme.accentOrange)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
    }

    private var deleteRow: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                Text("review.composer.delete".localized)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 17).fill(Color.red.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private func save() async {
        guard canSave, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let toastId = ToastCenter.shared.begin(message: "review.toast.saving".localized)
        do {
            try await ReviewActions.shared.setReview(
                mediaType: mediaType, tmdbId: tmdbId,
                content: content, containsSpoilers: containsSpoilers
            )
            ToastCenter.shared.complete(toastId, message: "review.toast.saved".localized)
            onSaved()
            dismiss()
        } catch {
            ToastCenter.shared.fail(toastId, message: "review.toast.failed".localized)
        }
    }

    private func deleteReview() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let toastId = ToastCenter.shared.begin(message: "review.toast.removing".localized)
        do {
            try await ReviewActions.shared.removeReview(mediaType: mediaType, tmdbId: tmdbId)
            ToastCenter.shared.complete(toastId, message: "review.toast.removed".localized)
            onDeleted()
            dismiss()
        } catch {
            ToastCenter.shared.fail(toastId, message: "review.toast.failed".localized)
        }
    }
}

#Preview("Composer — nuova") {
    Color.theme.background
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ReviewComposerView(mediaType: "movie", tmdbId: 157336)
        }
}

#Preview("Composer — modifica") {
    Color.theme.background
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ReviewComposerView(
                mediaType: "movie", tmdbId: 157336,
                existingReview: .init(
                    id: "prev",
                    content: "Un viaggio che ti lascia senza fiato dal primo all'ultimo minuto.",
                    containsSpoilers: true
                )
            )
        }
}
