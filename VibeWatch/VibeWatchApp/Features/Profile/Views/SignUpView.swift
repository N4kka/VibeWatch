import SwiftUI

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSignIn = false
    @State private var emailTouched = false
    @State private var passwordTouched = false
    @State private var confirmPasswordTouched = false
    
    var isEmailValid: Bool {
        ValidationHelper.isValidEmail(email)
    }
    
    var isPasswordValid: Bool {
        ValidationHelper.isValidPassword(password)
    }
    
    var passwordsMatch: Bool {
        password == confirmPassword && !confirmPassword.isEmpty
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        headerView
                        
                        inputFields
                        
                        signUpButton
                        
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
            .sheet(isPresented: $showSignIn) {
                SignInView()
                    .environmentObject(appState)
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            Text("auth.createAccount".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("auth.joinVibeWatch".localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
        }
        .padding(.top, 20)
    }
    
    private var inputFields: some View {
        VStack(spacing: 16) {
            // Username
            VStack(alignment: .leading, spacing: 4) {
                TextField("auth.usernamePlaceholder".localized, text: $username)
                    .textFieldStyle(CustomTextFieldStyle())
                    .autocapitalization(.none)
                    .textContentType(.username)
            }
            
            // Email with validation
            VStack(alignment: .leading, spacing: 4) {
                TextField("auth.emailPlaceholder".localized, text: $email)
                    .textFieldStyle(CustomTextFieldStyle())
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .onChange(of: email) { _ in
                        emailTouched = true
                    }
                
                if emailTouched && !email.isEmpty && !isEmailValid {
                    Text("auth.invalidEmail".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.leading, 16)
                }
            }
            
            // Password with validation
            VStack(alignment: .leading, spacing: 4) {
                SecureField("auth.passwordPlaceholder".localized, text: $password)
                    .textFieldStyle(CustomTextFieldStyle())
                    .textContentType(.newPassword)
                    .onChange(of: password) { _ in
                        passwordTouched = true
                    }
                
                if passwordTouched && !password.isEmpty && !isPasswordValid {
                    Text("auth.invalidPassword".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.leading, 16)
                }
            }
            
            // Confirm Password with validation
            VStack(alignment: .leading, spacing: 4) {
                SecureField("auth.confirmPasswordPlaceholder".localized, text: $confirmPassword)
                    .textFieldStyle(CustomTextFieldStyle())
                    .textContentType(.newPassword)
                    .onChange(of: confirmPassword) { _ in
                        confirmPasswordTouched = true
                    }
                
                if confirmPasswordTouched && !confirmPassword.isEmpty && !passwordsMatch {
                    Text("auth.passwordsDontMatch".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.leading, 16)
                }
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
    
    private var signUpButton: some View {
        Button {
            Task {
                await handleSignUp()
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("auth.signUp".localized)
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
                        await handleAppleSignUp()
                    }
                }
            )
            
            SocialButton(
                icon: "g.circle.fill",
                title: "Continue with Google",
                action: {
                    Task {
                        await handleGoogleSignUp()
                    }
                }
            )
        }
        .padding(.horizontal, 20)
    }
    
    private var bottomLink: some View {
        Button {
            showSignIn = true
        } label: {
            HStack(spacing: 4) {
                Text("auth.alreadyHaveAccount".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                
                Text("auth.signIn".localized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(.top, 8)
    }
    
    private var isFormValid: Bool {
        !username.isEmpty &&
        !email.isEmpty &&
        isEmailValid &&
        !password.isEmpty &&
        isPasswordValid &&
        passwordsMatch
    }
    
    private func handleSignUp() async {
        errorMessage = nil
        isLoading = true
        
        do {
            let user = try await AuthService.shared.signUp(
                username: username,
                email: email,
                password: password
            )
            
            appState.currentUser = user
            appState.isAuthenticated = true
            appState.showSuccessToast = true
            appState.toastMessage = "Account created successfully!"
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            appState.showErrorToast = true
            appState.toastMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func handleAppleSignUp() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let user = try await AuthService.shared.signInWithApple()
            appState.currentUser = user
            appState.isAuthenticated = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func handleGoogleSignUp() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let user = try await AuthService.shared.signInWithGoogle()
            appState.currentUser = user
            appState.isAuthenticated = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    

}

struct SocialButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                
                Text(title)
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundColor(.theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }
}
