import SwiftUI

struct MediaFilterSwitcher: View {
    @Binding var selectedFilter: MediaFilter

    var body: some View {
        SegmentedPicker(
            items: [MediaFilter.all, .movies, .tvSeries],
            selection: $selectedFilter,
            label: { filterTitle(for: $0) }
        )
    }
    
    private func filterTitle(for filter: MediaFilter) -> String {
        switch filter {
        case .all:
            return "list.all".localized
        case .movies:
            return "list.movies".localized
        case .tvSeries:
            return "list.tvShows".localized
        }
    }
}

enum MediaFilter: Hashable {
    case all
    case movies
    case tvSeries
}

#Preview {
    MediaFilterSwitcher(selectedFilter: .constant(.all))
        .background(Color.theme.background)
        .padding()
}
