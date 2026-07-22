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

struct ListTypeSwitcher: View {
    @Binding var selectedType: ListViewType

    /// System lists first, the custom-lists collection ("Raccolte") last — matches the redesign.
    private static let orderedTypes: [ListViewType] = [.watchlist, .seen, .liked, .myLists]

    var body: some View {
        SegmentedPicker(
            items: Self.orderedTypes,
            selection: $selectedType,
            label: { $0.displayName }
        )
    }
}

enum LibrarySection: String, CaseIterable {
    case myLists = "lists.section.myLists"
    case tvTracking = "lists.section.tvTracking"
    case publicLists = "lists.section.publicLists"

    var displayName: String {
        rawValue.localizedMainSafe()
    }
}

struct LibrarySectionSwitcher: View {
    @Binding var selectedSection: LibrarySection
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 24) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                let isSelected = selectedSection == section
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSection = section
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(section.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(isSelected ? .theme.textPrimary : .theme.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)

                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 2.5)
                            if isSelected {
                                Capsule()
                                    .fill(Color.theme.accentOrange)
                                    .frame(height: 2.5)
                                    .matchedGeometryEffect(id: "sectionUnderline", in: underline)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
    }
}

#Preview {
    ListTypeSwitcher(selectedType: .constant(.watchlist))
        .background(Color.theme.background)
}
