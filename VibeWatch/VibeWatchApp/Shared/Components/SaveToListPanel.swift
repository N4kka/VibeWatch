import SwiftUI

struct SaveToListPanel: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var listManager = ListManager.shared
    @EnvironmentObject var appState: AppState
    @State private var showCreateList = false
    @State private var showAuthGate = false
    @State private var newListName = ""
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    let movie: Movie
    let mediaType: MediaType
    
    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 12)
            
            // Header
            HStack {
                Text("movieDetail.save".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Lists
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(listManager.lists.filter { $0.type != .seen && $0.type != .liked && $0.type != .disliked }) { list in
                        ListRow(
                            list: list,
                            isInList: listManager.isInList(listId: list.id, mediaId: movie.id, mediaType: mediaType),
                            isLocked: list.type == .custom && !appState.isAuthenticated
                        ) {
                            Task {
                                do {
                                    if listManager.isInList(listId: list.id, mediaId: movie.id, mediaType: mediaType) {
                                        if let existing = list.items.first(where: { $0.mediaId == movie.id }) {
                                            try await listManager.removeFromList(listId: list.id, itemId: existing.id)
                                        }
                                    } else {
                                        try await listManager.addToList(listId: list.id, movie: movie, mediaType: mediaType)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        dismiss()
                                    }
                                } catch {
                                    // Check if it's an authentication error
                                    if let listError = error as? ListError, listError == .authenticationRequired {
                                        showAuthGate = true
                                    } else {
                                        ErrorHandler.shared.handle(error, context: "Save to list")
                                    }
                                }
                            }
                        }
                    }
                    
                    // Create New List Button
                    Button {
                        // Check if user is authenticated
                        if appState.isAuthenticated {
                            showCreateList = true
                        } else {
                            // Show authentication gate for anonymous users
                            showAuthGate = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.theme.accentOrange)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("clips.createNewList".localized)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.theme.textPrimary)
                                
                                if !appState.isAuthenticated {
                                    Text("Account required")
                                        .font(.system(size: 12))
                                        .foregroundColor(.theme.textSecondary)
                                }
                            }
                            
                            Spacer()
                            
                            if !appState.isAuthenticated {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.theme.textSecondary)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                .padding(.vertical, 12)
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.5)
        .background(Color.theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .alert("lists.createList".localized, isPresented: $showCreateList) {
            TextField("lists.listNamePlaceholder".localized, text: $newListName)
            Button("common.cancel".localized, role: .cancel) {
                newListName = ""
            }
            Button("common.save".localized) {
                if !newListName.isEmpty {
                    Task {
                        do {
                            try await listManager.createList(name: newListName)
                            newListName = ""
                        } catch {
                            print("⚠️ Failed to create list: \(error)")
                        }
                    }
                }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .fullScreenCover(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
        }
        .onChange(of: listManager.softLimitWarningMessage) { newValue in
            guard let message = newValue else { return }
            alertTitle = "Heads Up"
            alertMessage = message
            showAlert = true
            listManager.softLimitWarningMessage = nil
        }
    }
}

struct ListRow: View {
    let list: MediaList
    let isInList: Bool
    let isLocked: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: list.type.icon)
                    .font(.system(size: 20))
                    .foregroundColor(.theme.accentOrange)
                    .frame(width: 28)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(list.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                        
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }
                    
                    Text("\(list.items.count) \("common.items".localized)")
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: isInList ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(isInList ? .theme.accentOrange : .theme.textSecondary)
                    .opacity(isLocked ? 0.5 : 1.0)
            }
            .padding()
            .background(Color.white.opacity(isLocked ? 0.03 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isLocked ? 0.6 : 1.0)
        }
        .padding(.horizontal, 20)
        .disabled(isLocked && !isInList) // Can't add to locked lists, but can remove if already in
    }
}
