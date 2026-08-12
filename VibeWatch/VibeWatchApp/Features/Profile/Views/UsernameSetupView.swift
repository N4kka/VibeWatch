import SwiftUI

/// SPEC v3 §3.7 — la schermata di scelta dello username.
///
/// Compare una volta sola, al primo accesso dopo che gli username esistono. Non è saltabile per
/// chi non ne ha uno: senza username non si compare in `public_profiles`, quindi il profilo non
/// esiste per nessun altro. Per chi ce l'ha già è una conferma, e lì saltare è legittimo — il
/// nome glielo abbiamo dato noi, ma è valido e unico.
struct UsernameSetupView: View {
    @StateObject private var viewModel = UsernameSetupViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Chiamata quando lo username è stato salvato o l'utente ha rimandato.
    var onFinished: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            field
            statusLine
            Spacer()
            actions
        }
        .padding(24)
        .background(Color.theme.backgroundDark.ignoresSafeArea())
        .task { await viewModel.load() }
        // Niente `interactiveDismissDisabled` per chi deve sceglierne uno: una schermata da cui non
        // si esce è una trappola, e la stessa app ne ha già avuta una (il pannello AI senza porta).
        // Chi rimanda la ritrova al prossimo avvio, che è il modo garbato di insistere.
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleKey.localized)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            Text(subtitleKey.localized)
                .font(.system(size: 15))
                .foregroundColor(.theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleKey: String {
        switch viewModel.mode {
        case .confirm: return "username.confirm.title"
        case .choose:  return "username.choose.title"
        }
    }

    private var subtitleKey: String {
        switch viewModel.mode {
        case .confirm: return "username.confirm.subtitle"
        case .choose:  return "username.choose.subtitle"
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Text("@")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
            TextField("username.placeholder".localized, text: $viewModel.typed)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        switch viewModel.status {
        case .available: return .green.opacity(0.6)
        case .unavailable: return .red.opacity(0.6)
        case .checking, .idle: return .white.opacity(0.12)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        // L'altezza è fissa: senza, la comparsa del messaggio sposta i pulsanti mentre si digita
        // e si finisce per premere quello sbagliato.
        Group {
            switch viewModel.status {
            case .idle:
                Text("username.hint".localized)
                    .foregroundColor(.theme.textSecondary)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("username.checking".localized).foregroundColor(.theme.textSecondary)
                }
            case .available:
                Label("username.available".localized, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .unavailable(let key):
                Label(key.localized, systemImage: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
        .font(.system(size: 13))
        .frame(height: 20, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let error = viewModel.saveError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { if await viewModel.submit() { onFinished(); dismiss() } }
            } label: {
                Group {
                    if viewModel.isSaving {
                        ProgressView().tint(.black)
                    } else {
                        Text(confirmKey.localized).font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .foregroundColor(.black)
                .background(viewModel.canSubmit ? Color.theme.accentOrange : Color.gray.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!viewModel.canSubmit)

            Button {
                onFinished()
                dismiss()
            } label: {
                Text("username.later".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }

    private var confirmKey: String {
        switch viewModel.mode {
        case .confirm: return "username.confirm.action"
        case .choose:  return "username.choose.action"
        }
    }
}
