import SwiftUI

struct SaveToListPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.listRepository) private var listRepository
    @EnvironmentObject var appState: AppState
    @State private var lists: [MediaList] = []
    @State private var showCreateList = false
    @State private var showAuthGate = false
    @State private var newListName = ""
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    let movie: Movie
    let mediaType: MediaType

    private var userId: String { appState.currentUser?.id ?? "anonymous" }

    private func isInList(_ list: MediaList) -> Bool {
        list.items.contains { $0.mediaId == movie.id && $0.mediaType == mediaType }
    }

    var body: some View {
        VStack(spacing: 0) {
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

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(lists.filter { $0.type != .seen && $0.type != .liked && $0.type != .disliked }) { list in
                        ListRow(
                            list: list,
                            isInList: isInList(list),
                            isLocked: list.type == .custom && !appState.isAuthenticated
                        ) {
                            Task {
                                do {
                                    let identifier = MediaIdentifier(id: movie.id, mediaType: mediaType)
                                    if isInList(list) {
                                        try await listRepository.removeItem(identifier, from: list.id, userId: userId)
                                    } else {
                                        let item = MediaListItem(
                                            mediaId: movie.id,
                                            mediaType: mediaType,
                                            title: movie.title,
                                            posterPath: movie.posterPath,
                                            runtime: movie.runtime,
                                            voteAverage: movie.voteAverage,
                                            voteCount: movie.voteCount,
                                            releaseDate: movie.releaseDate,
                                            overview: movie.overview
                                        )
                                        try await listRepository.addItem(ListItemMutation(userId: userId, listId: list.id, item: item))
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        dismiss()
                                    }
                                } catch {
                                    ErrorHandler.shared.handle(error, context: "Save to list")
                                }
                            }
                        }
                    }

                    Button {
                        if appState.isAuthenticated {
                            showCreateList = true
                        } else {
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
                                    Text("auth.gate.accountRequired".localized)
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
        .task {
            for await snapshot in listRepository.lists(for: userId) {
                lists = snapshot
            }
        }
        .alert("lists.createList".localized, isPresented: $showCreateList) {
            TextField("lists.listNamePlaceholder".localized, text: $newListName)
            Button("common.cancel".localized, role: .cancel) {
                newListName = ""
            }
            Button("common.save".localized) {
                if !newListName.isEmpty {
                    Task {
                        do {
                            let list = MediaList(name: newListName, type: .custom)
                            try await listRepository.createList(list, userId: userId)
                            newListName = ""
                        } catch {
                            Logger.warning("Failed to create list: \(error)")
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
                .presentationBackground(.clear)
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
        .disabled(isLocked && !isInList)
    }
}
