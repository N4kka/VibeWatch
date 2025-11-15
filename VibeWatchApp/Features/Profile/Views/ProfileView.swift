import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var showLogin = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                if appState.isAuthenticated {
                    authenticatedView
                } else {
                    unauthenticatedView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.theme.textPrimary)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
    }
    
    private var authenticatedView: some View {
        ScrollView {
            VStack(spacing: 24) {
                profileHeader
                
                settingsSection
                
                Button {
                    // TODO: Logout
                    appState.isAuthenticated = false
                    dismiss()
                } label: {
                    Text("Logout")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 20)
        }
    }
    
    private var unauthenticatedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.circle")
                .font(.system(size: 80))
                .foregroundColor(.theme.textSecondary)
            
            Text("Sign in to VibeWatch")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("Create lists, save clips, and personalize your experience")
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showLogin = true
            } label: {
                Text("Sign In")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            
            Button {
                showLogin = true
            } label: {
                Text("Create Account")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
        }
    }
    
    private var profileHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.theme.textSecondary)
            
            Text(appState.currentUser?.displayName ?? "User")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if let email = appState.currentUser?.email {
                Text(email)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
        }
        .padding()
    }
    
    private var settingsSection: some View {
        VStack(spacing: 0) {
            SettingsRow(
                icon: "bell",
                title: "Notifications",
                action: {}
            )
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            SettingsRow(
                icon: "play.tv",
                title: "Streaming Services",
                action: {}
            )
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            SettingsRow(
                icon: "gear",
                title: "Settings",
                action: {}
            )
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            SettingsRow(
                icon: "questionmark.circle",
                title: "Help & Support",
                action: {}
            )
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.theme.accentOrange)
                    .frame(width: 30)
                
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textPrimary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
            .padding()
        }
    }
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var isLogin = true
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    Text(isLogin ? "Sign In" : "Create Account")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .padding(.top, 40)
                    
                    VStack(spacing: 16) {
                        TextField("Email", text: $email)
                            .textFieldStyle(CustomTextFieldStyle())
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                        
                        SecureField("Password", text: $password)
                            .textFieldStyle(CustomTextFieldStyle())
                    }
                    .padding(.horizontal, 20)
                    
                    Button {
                        handleAuth()
                    } label: {
                        Text(isLogin ? "Sign In" : "Create Account")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.theme.accentOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 20)
                    .disabled(email.isEmpty || password.isEmpty)
                    
                    Button {
                        isLogin.toggle()
                    } label: {
                        Text(isLogin ? "Don't have an account? Sign Up" : "Already have an account? Sign In")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.accentOrange)
                    }
                    
                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.theme.textPrimary)
                }
            }
        }
    }
    
    private func handleAuth() {
        // TODO: Implement Supabase authentication
        appState.isAuthenticated = true
        dismiss()
    }
}

struct CustomTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
            .foregroundColor(.theme.textPrimary)
    }
}
