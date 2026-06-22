import SwiftUI

struct TVShowsTrackingView: View {
    @StateObject private var viewModel = TVShowsTrackingViewModel()
    @State private var selectedFilter: TVTrackingFilter = .continuing

    var body: some View {
        VStack(spacing: 0) {
            tvTrackingSwitcher

            let items = viewModel.items(for: selectedFilter)

            HStack {
                Text(String(format: "tvTracking.titlesCount".localized, items.count))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                if items.isEmpty {
                    emptyStateView
                        .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(items) { item in
                            TVTrackingCard(item: item, bucket: selectedFilter)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 100)
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }

    private var tvTrackingSwitcher: some View {
        SegmentedPicker(
            items: Array(TVTrackingFilter.allCases),
            selection: $selectedFilter,
            label: { $0.displayName }
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 48))
                .foregroundColor(.theme.textSecondary)
            Text("tvTracking.emptyState".localized)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
