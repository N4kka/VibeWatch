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
    @State private var showConfirmUpdate = false
    
    private var title: String {
        switch mode {
        case .change:
            return "profile.changePassword".localized
        case .recovery:
            return "auth.resetPassword".localized
        }
    }
    
    private var descriptionText: String {
        "auth.setNewPasswordDescription".localized
    }
    
    private var isFormValid: Bool {
        ValidationHelper.isValidPassword(newPassword) && newPassword == confirmPassword
    }
    
    var body: some View {
        ZStack {
            NavigationView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                        
                        Text(descriptionText)
                            .font(.system(size: 15))
                            .foregroundColor(.theme.textSecondary)
                    }
                    
                    VStack(spacing: 12) {
                        SecureField("auth.passwordPlaceholder".localized, text: $newPassword)
                            .textContentType(.newPassword)
                            .textFieldStyle(CustomTextFieldStyle())
                        
                        SecureField("auth.confirmPasswordPlaceholder".localized, text: $confirmPassword)
                            .textContentType(.newPassword)
                            .textFieldStyle(CustomTextFieldStyle())
                        
                        if !newPassword.isEmpty && !ValidationHelper.isValidPassword(newPassword) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("auth.invalidPassword".localized)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.red)
                                
                                ForEach(ValidationHelper.getPasswordRequirements(), id: \.self) { requirement in
                                    Text("• \(requirement)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.theme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                        
                        if !confirmPassword.isEmpty && newPassword != confirmPassword {
                            Text("auth.passwordsDontMatch".localized)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
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
                        showConfirmUpdate = true
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("auth.updatePassword".localized)
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
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("profile.cancel".localized) {
                            closeSheet()
                        }
                        .foregroundColor(.theme.textPrimary)
                    }
                }
            }
            .presentationDetents([.fraction(0.55), .large])
            .presentationDragIndicator(.visible)
            
            if showConfirmUpdate {
                popupOverlayBackground(onTap: {
                    showConfirmUpdate = false
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                ConfirmationPopup(
                    title: "auth.confirmChangePasswordTitle".localized,
                    message: "auth.confirmChangePasswordMessage".localized,
                    confirmTitle: "common.confirm".localized,
                    cancelTitle: "common.cancel".localized,
                    isDestructive: false,
                    onConfirm: {
                        showConfirmUpdate = false
                        Task {
                            await updatePassword()
                        }
                    },
                    onCancel: {
                        showConfirmUpdate = false
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
    
    private func updatePassword() async {
        guard isFormValid else { return }
        
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        do {
            try await authService.updatePassword(to: newPassword)
            appState.isAuthenticated = authService.isAuthenticated
            appState.currentUser = authService.currentUser
            successMessage = "auth.passwordResetSuccess".localized
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                closeSheet()
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
        .presentationDetents([.fraction(0.5), .large])
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
