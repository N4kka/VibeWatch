import SwiftUI

struct MediaFilterSwitcher: View {
    @Binding var selectedFilter: MediaFilter
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach([MediaFilter.all, MediaFilter.movies, MediaFilter.tvSeries], id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = filter
                    }
                } label: {
                    Text(filterTitle(for: filter))
                        .font(.system(size: 12, weight: selectedFilter == filter ? .semibold : .medium))
                        .foregroundColor(selectedFilter == filter ? .black : .theme.textSecondary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(
                            selectedFilter == filter ?
                            Color.theme.accentOrange :
                            Color.white.opacity(0.1)
                        )
                        .clipShape(Capsule())
                }
            }
            
            Spacer()
        }
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
