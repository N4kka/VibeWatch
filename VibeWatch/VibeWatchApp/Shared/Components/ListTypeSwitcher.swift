import SwiftUI

enum ListViewType: String, CaseIterable {
    case myLists = "lists.myLists"
    case watchlist = "lists.watchlist"
    case seen = "lists.seen"
    case liked = "lists.liked"
    
    var displayName: String {
        rawValue.localizedMainSafe()
    }
}

struct ListTypeSwitcher: View {
    @Binding var selectedType: ListViewType
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ListViewType.allCases, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedType = type
                    }
                } label: {
                    Text(type.displayName)
                        .font(.system(size: 13, weight: selectedType == type ? .semibold : .medium))
                        .foregroundColor(selectedType == type ? .theme.accentOrange : .theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .clipShape(Capsule())
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
    }
}

#Preview {
    ListTypeSwitcher(selectedType: .constant(.watchlist))
        .background(Color.theme.background)
}
