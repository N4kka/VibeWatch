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
        SegmentedPicker(
            items: Array(ListViewType.allCases),
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

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSection = section
                    }
                } label: {
                    Text(section.displayName)
                        .font(.system(size: 13, weight: selectedSection == section ? .semibold : .medium))
                        .foregroundColor(selectedSection == section ? .theme.accentOrange : .theme.textSecondary)
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
