import SwiftUI

enum ListViewType: String, CaseIterable {
    case myLists = "lists.myLists"
    case watchlist = "lists.watchlist"
    case seen = "lists.seen"
    case liked = "lists.liked"
    
    var displayName: String {
        switch self {
        // "Le Mie Liste" collided with the section tab of the same name, so the custom-lists
        // chip is now labelled "Raccolte" / "Collections".
        case .myLists: return "lists.collections".localizedMainSafe()
        default: return rawValue.localizedMainSafe()
        }
    }
}

/// Redesign 2.0 — chips pill come nel prototipo: la selezione è arancio tenue con bordo, non
/// un segmented pieno. Le liste pubbliche non sono più una sezione qui: vivono nel tab Social,
/// quindi lo switcher My/Public è sparito insieme al suo enum.
struct ListTypeSwitcher: View {
    @Binding var selectedType: ListViewType

    /// System lists first, the custom-lists collection ("Raccolte") last — matches the redesign.
    private static let orderedTypes: [ListViewType] = [.watchlist, .seen, .liked, .myLists]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.orderedTypes, id: \.self) { type in
                let isSelected = selectedType == type
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedType = type }
                } label: {
                    Text(type.displayName)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(isSelected ? .theme.accentOrange : .theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? Color.theme.accentOrange.opacity(0.14) : Color.white.opacity(0.06))
                        .overlay(
                            Capsule().stroke(
                                isSelected ? Color.theme.accentOrange.opacity(0.5) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    ListTypeSwitcher(selectedType: .constant(.watchlist))
        .background(Color.theme.background)
}
