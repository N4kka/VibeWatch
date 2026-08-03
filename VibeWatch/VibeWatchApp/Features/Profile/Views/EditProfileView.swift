import SwiftUI

/// Editor del profilo personale. I campi restano locali finché non viene premuto Salva, così
/// Annulla non lascia modifiche parziali né carica una nuova foto per errore.
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService

    private let originalUsername: String
    private let originalDisplayName: String
    private let originalBio: String
    private let originalIsProfilePublic: Bool
    private let initialAvatarURL: String?
    private let onSaved: (_ username: String, _ bio: String?, _ isProfilePublic: Bool) -> Void

    @State private var displayName: String
    @State private var username: String
    @State private var bio: String
    @State private var isProfilePublic: Bool
    @State private var selectedImage: UIImage?
    @State private var showImagePicker = false
    @State private var usernameStatus: UsernameStatus = .idle
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    private enum UsernameStatus: Equatable {
        case idle
        case checking
        case available
        case unavailable(String)
    }

    init(
        user: User,
        username: String?,
        bio: String?,
        isProfilePublic: Bool,
        onSaved: @escaping (_ username: String, _ bio: String?, _ isProfilePublic: Bool) -> Void
    ) {
        let initialUsername = username ?? ""
        let initialDisplayName = user.displayName ?? ""
        let initialBio = bio ?? ""

        self.originalUsername = initialUsername
        self.originalDisplayName = initialDisplayName
        self.originalBio = initialBio
        self.originalIsProfilePublic = isProfilePublic
        self.initialAvatarURL = user.avatarURL
        self.onSaved = onSaved
        _displayName = State(initialValue: initialDisplayName)
        _username = State(initialValue: initialUsername)
        _bio = State(initialValue: initialBio)
        _isProfilePublic = State(initialValue: isProfilePublic)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    avatarEditor

                    editorSection(title: "profile.edit.information".localized) {
                        VStack(spacing: 0) {
                            labeledTextField(
                                title: "profile.edit.name".localized,
                                text: $displayName,
                                contentType: .name
                            )

                            rowDivider

                            usernameField

                            rowDivider

                            bioField
                        }
                    }

                    editorSection(title: "common.privacy".localized) {
                        Toggle(isOn: $isProfilePublic) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("profile.edit.publicProfile".localized)
                                    .font(.headline)
                                    .foregroundStyle(Color.theme.textPrimary)
                                Text("profile.edit.publicProfileSubtitle".localized)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.theme.textSecondary)
                            }
                        }
                        .tint(.theme.accentOrange)
                        .padding()
                    }

                    deleteAccountSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationTitle("profile.edit.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                        .foregroundStyle(Color.theme.textSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save".localized) {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.theme.accentOrange)
                    .disabled(!canSave)
                }
            }
            .disabled(isDeleting)
            .overlay {
                if isSaving || isDeleting {
                    ProgressView()
                        .tint(.theme.accentOrange)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .tint(.theme.accentOrange)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $selectedImage)
        }
        .task(id: username) {
            await checkUsernameAvailability()
        }
        .alert(
            "settings.deleteAccountWarningTitle".localized,
            isPresented: $showDeleteConfirmation
        ) {
            Button("common.cancel".localized, role: .cancel) {}
            Button("settings.deleteAccountConfirm".localized, role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text("settings.deleteAccountWarningMessage".localized)
        }
    }

    private var avatarEditor: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                avatarImage
                    .frame(width: 116, height: 116)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(Color.theme.accentOrange.opacity(0.65), lineWidth: 2)
                    }

                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(.theme.accentOrange)
                .accessibilityLabel("profile.edit.changePhoto".localized)
            }

            Button("profile.edit.changePhoto".localized) {
                showImagePicker = true
            }
            .font(.headline)
            .foregroundStyle(Color.theme.accentOrange)
        }
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let selectedImage {
            Image(uiImage: selectedImage)
                .resizable()
                .scaledToFill()
        } else if let initialAvatarURL, let url = URL(string: initialAvatarURL) {
            CachedAsyncImage(url: url, maxPixelSize: 320) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ProgressView()
            }
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.theme.textSecondary)
        }
    }

    private func editorSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.heavy))
                .kerning(1.4)
                .foregroundStyle(Color.theme.textSecondary)

            content()
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func labeledTextField(
        title: String,
        text: Binding<String>,
        contentType: UITextContentType?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.theme.textSecondary)

            TextField(title, text: text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.theme.textPrimary)
                .textContentType(contentType)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("auth.usernamePlaceholder".localized.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.theme.textSecondary)

            HStack(spacing: 4) {
                Text("@")
                    .foregroundStyle(Color.theme.textSecondary)
                TextField("username.placeholder".localized, text: $username)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Spacer(minLength: 8)
                usernameStatusView
            }

            if case .unavailable(let message) = usernameStatus {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("username.hint".localized)
                    .font(.caption)
                    .foregroundStyle(Color.theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var usernameStatusView: some View {
        switch usernameStatus {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Label("username.available".localized, systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .unavailable:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var bioField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("profile.edit.bio".localized.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.theme.textSecondary)
                Spacer()
                Text("\(bio.count)/200")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.theme.textSecondary)
            }

            TextEditor(text: $bio)
                .font(.body)
                .foregroundStyle(Color.theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88)
                .onChange(of: bio) { _, newValue in
                    if newValue.count > 200 {
                        bio = String(newValue.prefix(200))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if bio.isEmpty {
                        Text("profile.edit.bioPlaceholder".localized)
                            .font(.body)
                            .foregroundStyle(Color.theme.textSecondary)
                            .allowsHitTesting(false)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var deleteAccountSection: some View {
        VStack(spacing: 12) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Text("settings.deleteAccount".localized)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.red.opacity(0.45), lineWidth: 1)
            }

            Text("settings.deleteAccountWarningMessage".localized)
                .font(.footnote)
                .foregroundStyle(Color.theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var rowDivider: some View {
        Divider().overlay(Color.white.opacity(0.1))
    }

    private var normalizedUsername: String {
        UsernameRules.normalizeTyping(username)
    }

    private var normalizedBio: String? {
        let value = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var usernameChanged: Bool {
        normalizedUsername != originalUsername
    }

    private var canSave: Bool {
        guard !isSaving, !isDeleting,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UsernameRules.isWellFormed(normalizedUsername), bio.count <= 200 else { return false }

        if usernameChanged, usernameStatus != .available { return false }

        return displayName.trimmingCharacters(in: .whitespacesAndNewlines) != originalDisplayName
            || usernameChanged
            || normalizedBio != (originalBio.isEmpty ? nil : originalBio)
            || isProfilePublic != originalIsProfilePublic
            || selectedImage != nil
    }

    @MainActor
    private func checkUsernameAvailability() async {
        let candidate = normalizedUsername
        if candidate == originalUsername {
            usernameStatus = .idle
            return
        }
        if let problem = UsernameRules.problem(with: candidate) {
            usernameStatus = .unavailable(problem.messageKey.localized)
            return
        }

        usernameStatus = .checking
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
            try Task.checkCancellation()
            let available = try await SupabaseService.shared.usernameAvailable(candidate)
            try Task.checkCancellation()
            usernameStatus = available
                ? .available
                : .unavailable("username.error.taken".localized)
        } catch is CancellationError {
            return
        } catch {
            usernameStatus = .unavailable("username.error.checkFailed".localized)
        }
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            var savedUsername = originalUsername
            if usernameChanged {
                switch try await SupabaseService.shared.setUsername(normalizedUsername) {
                case .saved(let username, _):
                    savedUsername = username
                case .taken:
                    usernameStatus = .unavailable("username.error.taken".localized)
                    return
                case .reserved:
                    usernameStatus = .unavailable("username.error.reserved".localized)
                    return
                case .invalidFormat:
                    usernameStatus = .unavailable("username.error.invalidCharacters".localized)
                    return
                }
            }

            let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDisplayName != originalDisplayName {
                try await authService.updateUserProfile(
                    displayName: trimmedDisplayName,
                    avatarURL: nil
                )
            }

            try await SupabaseService.shared.updateOwnProfileDetails(
                bio: normalizedBio,
                isProfilePublic: isProfilePublic
            )

            if let selectedImage,
               let imageData = selectedImage.jpegData(compressionQuality: 0.75) {
                _ = try await authService.uploadAvatar(imageData: imageData)
            }

            appState.currentUser = authService.currentUser
            onSaved(savedUsername, normalizedBio, isProfilePublic)
            dismiss()
        } catch {
            Logger.error("[EditProfile] Save failed: \(error.localizedDescription)")
            errorMessage = "profile.edit.saveError".localized
        }
    }

    @MainActor
    private func deleteAccount() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await authService.deleteAccountPermanently()
            appState.isAuthenticated = false
            appState.currentUser = nil
            dismiss()
        } catch {
            Logger.error("[EditProfile] Account deletion failed: \(error.localizedDescription)")
            errorMessage = "settings.deleteAccountError".localized
        }
    }
}
