import SwiftUI

enum ListViewType: String, CaseIterable {
    case myLists = "My Lists"
    case watchlist = "Watchlist"
    case seen = "Seen"
    case liked = "Liked"
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
                    Text(type.rawValue)
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
