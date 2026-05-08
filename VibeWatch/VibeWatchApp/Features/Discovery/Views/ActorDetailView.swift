import SwiftUI

struct ActorDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ActorDetailViewModel
    @State private var showFullBiography = false

    let initialName: String
    let initialProfileURL: URL?
    let previousTitle: String

    init(
        actorId: Int,
        initialName: String,
        initialProfileURL: URL? = nil,
        previousTitle: String
    ) {
        _viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeActorDetailViewModel(personId: actorId)
        )
        self.initialName = initialName
        self.initialProfileURL = initialProfileURL
        self.previousTitle = previousTitle
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                actorHeaderView

                VStack(alignment: .leading, spacing: 24) {
                    identityBlock
                    biographySection

                    if let highlight = viewModel.mostPopularCredit {
                        KnownForHighlightCard(credit: highlight)
                    }

                    MediaFilterSwitcher(selectedFilter: $viewModel.selectedFilter)

                    LazyVStack(spacing: 12) {
                        ForEach(filmographyList) { credit in
                            NavigationLink(destination: destinationView(for: credit)) {
                                ActorFilmographyRow(credit: credit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        .background(Color.theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .swipeBackGesture { dismiss() }
        .task { await viewModel.loadDetails() }
    }

    private var filmographyList: [PersonCredit] {
        let list = viewModel.filteredCredits
        // In "All" mode, exclude the Known For card's credit to avoid showing it twice
        if viewModel.selectedFilter == .all, let top = viewModel.mostPopularCredit {
            return list.filter { !($0.id == top.id && $0.mediaType == top.mediaType) }
        }
        return list
    }

    @ViewBuilder
    private func destinationView(for credit: PersonCredit) -> some View {
        switch credit.mediaType {
        case .movie: MovieDetailView(movieId: credit.id)
        case .tv:    TVShowDetailView(tvShowId: credit.id)
        }
    }

    @ViewBuilder
    private var actorHeaderView: some View {
        ZStack(alignment: .top) {
            CachedAsyncImage(url: viewModel.person?.profileURL ?? initialProfileURL)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.theme.background.opacity(0.8),
                            Color.theme.background
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            HStack {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text(previousTitle)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Capsule())
                }

                Spacer()

                Text(viewModel.person?.name ?? initialName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // Balance spacer matching the back button width
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    Text(previousTitle).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
                .foregroundColor(.clear)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.clear)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.person?.name ?? initialName)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.theme.textPrimary)

            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .theme.accentOrange))
            } else if let error = viewModel.error {
                Button {
                    Task { await viewModel.loadDetails() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("actor.retry".localized)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                }
                .accessibilityLabel(error.localizedDescription)
            }

            if let birthdayLine = viewModel.birthdayLineText {
                Text(birthdayLine)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }

            if let pob = viewModel.person?.placeOfBirth, !pob.isEmpty {
                Text(pob)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var biographySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("actor.biography.title".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            if let biography = viewModel.person?.biography, !biography.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(biography)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(showFullBiography ? nil : 4)

                    if biography.count > 240 {
                        Button {
                            withAnimation(.easeInOut) {
                                showFullBiography.toggle()
                            }
                        } label: {
                            Text(showFullBiography ? "actor.biography.showLess".localized : "actor.biography.showMore".localized)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.theme.accentOrange)
                        }
                    }
                }
            } else if viewModel.isLoading {
                Text("actor.biography.loading".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            } else {
                Text("actor.biography.unavailable".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }
}
