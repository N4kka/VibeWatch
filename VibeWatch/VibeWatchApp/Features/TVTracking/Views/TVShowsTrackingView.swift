import SwiftUI

struct TVShowsTrackingView: View {
    @StateObject private var viewModel = TVShowsTrackingViewModel()
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var selectedFilter: TVTrackingFilter = .continuing
    @State private var showFilters = false
    @State private var filters = GlobalDiscoveryFilters()

    var body: some View {
        VStack(spacing: 0) {
            tvTrackingSwitcher

            filtersRow

            ScrollView {
                let items = viewModel.items(for: selectedFilter)
                if items.isEmpty {
                    emptyStateView
                        .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            MediaItemRow(
                                item: item,
                                isInSeenList: ListManager.shared.isInList(listId: ListManager.shared.seenList.id, mediaId: item.mediaId, mediaType: item.mediaType),
                                onMarkAsSeen: {},
                                onDelete: {}
                            )
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .overlay {
            if showFilters {
                GlobalFilterView(
                    filters: $filters,
                    isPresented: $showFilters,
                    onApply: { _ in }
                )
                .environmentObject(quotaManager)
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
        .padding(.bottom, 16)
    }

    private var filtersRow: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                withAnimation {
                    showFilters = true
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                        Text("filters.title".localized)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())

                    if filters.isActive {
                        Circle()
                            .fill(Color.theme.accentOrange)
                            .frame(width: 10, height: 10)
                            .offset(x: 4, y: -2)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
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
