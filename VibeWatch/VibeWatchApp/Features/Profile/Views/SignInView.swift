import SwiftUI

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @State private var emailOrUsername = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSignUp = false
    @State private var emailTouched = false
    @State private var passwordTouched = false
    @State private var showForgotPasswordSheet = false
    @State private var resetEmail = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        headerView
                        
                        inputFields
                        
                        forgotPasswordButton
                        
                        signInButton
                        
                        dividerView
                        
                        socialButtons
                        
                        bottomLink
                        
                        Spacer()
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("profile.cancel".localized) {
                        dismiss()
                    }
                    .foregroundColor(.theme.textPrimary)
                }
            }
            .sheet(isPresented: $showSignUp) {
                SignUpView()
                    .environmentObject(appState)
                    .environmentObject(authService)
            }
            .sheet(isPresented: $showForgotPasswordSheet) {
                ForgotPasswordSheet(initialEmail: resetEmail)
                    .environmentObject(authService)
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            Text("auth.welcomeBack".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("auth.signInContinue".localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
        }
        .padding(.top, 20)
    }
    
    private var inputFields: some View {
        VStack(spacing: 16) {
            TextField("profile.userNamePlaceholder".localized, text: $emailOrUsername)
                .textFieldStyle(CustomTextFieldStyle())
                .autocapitalization(.none)
                .textContentType(.username)
                .onChange(of: emailOrUsername) {_, _ in
                    emailTouched = true
                }
            
            SecureField("profile.passwordPlaceholder".localized, text: $password)
                .textFieldStyle(CustomTextFieldStyle())
                .textContentType(.password)
                .onChange(of: password) {_, _ in
                    passwordTouched = true
                }
            
            if emailTouched && emailOrUsername.contains("@") && !emailOrUsername.isEmpty && !isEmailOrUsernameValid {
                Text("auth.invalidEmail".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
            
            if passwordTouched && !password.isEmpty && !isPasswordValid {
                Text("auth.invalidPassword".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal, 20)
    }
    
    private var forgotPasswordButton: some View {
        Button {
            let trimmed = emailOrUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            resetEmail = trimmed.contains("@") ? trimmed : ""
            showForgotPasswordSheet = true
        } label: {
            Text("auth.forgotPassword".localized)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.theme.accentOrange)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 20)
    }
    
    private var signInButton: some View {
        Button {
            Task {
                await handleSignIn()
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("auth.signIn".localized)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(isFormValid ? Color.theme.accentOrange : Color.theme.accentOrange.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 20)
        .disabled(!isFormValid || isLoading)
    }
    
    private var dividerView: some View {
        HStack {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 1)
            
            Text("common.or".localized)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.theme.textSecondary)
                .padding(.horizontal, 12)
            
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.horizontal, 20)
    }
    
    private var socialButtons: some View {
        VStack(spacing: 12) {
            SocialButton(
                icon: "apple.logo",
                title: "Continue with Apple",
                action: {
                    Task {
                        await handleAppleSignIn()
                    }
                }
            )
            
            SocialButton(
                icon: "g.circle.fill",
                title: "Continue with Google",
                action: {
                    Task {
                        await handleGoogleSignIn()
                    }
                }
            )
        }
        .padding(.horizontal, 20)
    }
    
    private var bottomLink: some View {
        Button {
            dismiss()
            showSignUp = true
        } label: {
            HStack(spacing: 4) {
                Text("auth.dontHaveAccount".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                
                Text("auth.signUp".localized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(.top, 8)
    }
    
    private var isFormValid: Bool {
        isEmailOrUsernameValid && isPasswordValid
    }
    
    private var isEmailOrUsernameValid: Bool {
        let trimmed = emailOrUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            return ValidationHelper.isValidEmail(trimmed)
        } else {
            return !trimmed.isEmpty
        }
    }
    
    private var isPasswordValid: Bool {
        ValidationHelper.isValidPassword(password)
    }
    
    private func handleSignIn() async {
        errorMessage = nil
        isLoading = true
        
        do {
            let credential = emailOrUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = try await authService.signIn(
                emailOrUsername: credential,
                password: password
            )
            
            appState.currentUser = user
            appState.isAuthenticated = true
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func handleAppleSignIn() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let user = try await authService.signInWithApple()
            appState.currentUser = user
            appState.isAuthenticated = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func handleGoogleSignIn() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let user = try await authService.signInWithGoogle()
            appState.currentUser = user
            appState.isAuthenticated = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    

}
