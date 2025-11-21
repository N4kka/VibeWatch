import SwiftUI

struct SaveToListPanel: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var listManager = ListManager.shared
    @State private var showCreateList = false
    @State private var newListName = ""
    
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
                            isInList: listManager.isInList(listId: list.id, mediaId: movie.id, mediaType: mediaType)
                        ) {
                            if listManager.isInList(listId: list.id, mediaId: movie.id, mediaType: mediaType) {
                                listManager.removeFromList(listId: list.id, itemId: list.items.first(where: { $0.mediaId == movie.id })?.id ?? "")
                            } else {
                                listManager.addToList(listId: list.id, movie: movie, mediaType: mediaType)
                            }
                            // Auto-close panel after selection
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                dismiss()
                            }
                        }
                    }
                    
                    // Create New List Button
                    Button {
                        showCreateList = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.theme.accentOrange)
                            
                            Text("clips.createNewList".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                            
                            Spacer()
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
                    listManager.createList(name: newListName)
                    newListName = ""
                }
            }
        }
    }
}

struct ListRow: View {
    let list: MediaList
    let isInList: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: list.type.icon)
                    .font(.system(size: 20))
                    .foregroundColor(.theme.accentOrange)
                    .frame(width: 28)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Text("\(list.items.count) \("common.items".localized)")
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: isInList ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(isInList ? .theme.accentOrange : .theme.textSecondary)
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 20)
    }
}
