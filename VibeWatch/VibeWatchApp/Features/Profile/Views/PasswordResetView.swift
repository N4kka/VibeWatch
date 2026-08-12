import SwiftUI

struct PasswordResetView: View {
    enum Mode {
        case recovery
        case change
    }

    let mode: Mode
    @Binding var isPresented: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var revealPassword = false
    @State private var showForgotPassword = false

    private var title: String {
        switch mode {
        case .change:
            return "profile.changePassword".localized
        case .recovery:
            return "auth.resetPassword".localized
        }
    }

    private var subtitle: String {
        switch mode {
        case .change:
            // Solo un avviso: il logout dagli altri dispositivi lo fa Supabase invalidando i
            // refresh token, non c'è nulla da implementare qui.
            return "auth.changePasswordSubtitle".localized
        case .recovery:
            return "auth.setNewPasswordDescription".localized
        }
    }

    private var isFormValid: Bool {
        ValidationHelper.isValidPassword(newPassword) && newPassword == confirmPassword
    }

    var body: some View {
        VWModalSheet(
            title: title,
            subtitle: subtitle,
            onClose: closeSheet,
            primaryTitle: "auth.updatePassword".localized,
            primaryEnabled: isFormValid && !isLoading,
            primaryAction: { Task { await updatePassword() } },
            secondaryTitle: "profile.cancel".localized,
            secondaryAction: closeSheet
        ) {
            VStack(alignment: .leading, spacing: 14) {
                passwordField(
                    placeholder: "auth.newPasswordPlaceholder".localized,
                    text: $newPassword,
                    showsReveal: true
                )

                PasswordRequirementsChecklist(password: newPassword)

                passwordField(
                    placeholder: "auth.confirmPasswordPlaceholder".localized,
                    text: $confirmPassword,
                    showsReveal: false
                )

                if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    Text("auth.passwordsDontMatch".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                if mode == .change {
                    Button {
                        showForgotPassword = true
                    } label: {
                        Text("auth.forgotCurrentPassword".localized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                    }
                    .padding(.top, 2)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                if let successMessage {
                    Text(successMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .vwModalPresentation()
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordSheet()
                .environmentObject(authService)
        }
    }

    @ViewBuilder
    private func passwordField(
        placeholder: String,
        text: Binding<String>,
        showsReveal: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if showsReveal && revealPassword {
                    TextField(placeholder, text: text)
                        .textContentType(.newPassword)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField(placeholder, text: text)
                        .textContentType(.newPassword)
                }
            }
            .foregroundColor(.theme.textPrimary)

            if showsReveal {
                Button {
                    revealPassword.toggle()
                } label: {
                    Text((revealPassword ? "auth.hide" : "auth.show").localized)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.065)))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func updatePassword() async {
        guard isFormValid else { return }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            try await authService.updatePassword(to: newPassword)
            successMessage = "auth.passwordResetSuccess".localized
            ToastCenter.shared.show(success: "auth.passwordResetSuccess".localized)

            // Wait briefly then complete recovery
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task {
                    // This unmasks the session and refreshes the profile,
                    // leaving the user signed in on the Discovery view.
                    await authService.completeRecovery()

                    // Force AppState to refresh from AuthService so the UI updates
                    await appState.checkAuthState()

                    dismiss()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func closeSheet() {
        if mode == .recovery {
            authService.isPasswordRecoveryFlowPresented = false
        }
        isPresented = false
        dismiss()
    }
}

struct ForgotPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authService: AuthService
    
    @State private var email: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @FocusState private var emailFocused: Bool
    
    init(initialEmail: String = "") {
        _email = State(initialValue: initialEmail)
    }
    
    private var isFormValid: Bool {
        ValidationHelper.isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("auth.resetPassword".localized)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Text("auth.resetPasswordDescription".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.theme.textSecondary)
                }
                
                VStack(spacing: 12) {
                    TextField("auth.emailPlaceholder".localized, text: $email)
                        .textFieldStyle(CustomTextFieldStyle())
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .focused($emailFocused)
                    
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if let successMessage {
                        Text(successMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                Spacer()
                
                Button {
                    Task {
                        await sendReset()
                    }
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("auth.sendResetLink".localized)
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .foregroundColor(.white)
                    .background(isFormValid ? Color.theme.accentOrange : Color.theme.accentOrange.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!isFormValid || isLoading)
            }
            .padding(20)
            .background(Color.theme.background.ignoresSafeArea())
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    emailFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("profile.cancel".localized) {
                        dismiss()
                    }
                    .foregroundColor(.theme.textPrimary)
                }
            }
        }
        .presentationDetents([.fraction(0.5)]) // Fixed height to prevent expansion
        .presentationDragIndicator(.visible)
    }
    
    private func sendReset() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        do {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            try await authService.sendPasswordReset(email: trimmed)
            successMessage = "auth.resetEmailSent".localized
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}
