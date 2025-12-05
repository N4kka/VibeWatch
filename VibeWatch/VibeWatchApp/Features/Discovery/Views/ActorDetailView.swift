import SwiftUI

struct ActorDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ActorDetailViewModel
    @State private var showFullBiography = false
    
    let initialName: String
    let initialProfileURL: URL?
    let onSelectCredit: ((PersonCredit) -> Void)?
    
    init(
        actorId: Int,
        initialName: String,
        initialProfileURL: URL? = nil,
        onSelectCredit: ((PersonCredit) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: ActorDetailViewModel(personId: actorId))
        self.initialName = initialName
        self.initialProfileURL = initialProfileURL
        self.onSelectCredit = onSelectCredit
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                biographySection
                
                if !viewModel.movieCredits.isEmpty {
                    FilmographySection(
                        title: "actor.filmography.movies".localized,
                        credits: viewModel.movieCredits,
                        onSelect: handleSelect
                    )
                }
                
                if !viewModel.tvCredits.isEmpty {
                    FilmographySection(
                        title: "actor.filmography.tv".localized,
                        credits: viewModel.tvCredits,
                        onSelect: handleSelect
                    )
                }
            }
            .padding(20)
        }
        .background(Color.theme.background.ignoresSafeArea())
        .task {
            await viewModel.loadDetails()
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .padding(10)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            CachedAsyncImage(url: viewModel.person?.profileURL ?? initialProfileURL)
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.person?.name ?? initialName)
                    .font(.system(size: 20, weight: .bold))
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
            }
            Spacer()
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
                    
                    if shouldShowToggle(for: biography) {
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
    
    private func shouldShowToggle(for biography: String) -> Bool {
        biography.count > 240
    }
    
    private func handleSelect(_ credit: PersonCredit) {
        onSelectCredit?(credit)
        dismiss()
    }
}

private struct FilmographySection: View {
    let title: String
    let credits: [PersonCredit]
    let onSelect: (PersonCredit) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(credits.prefix(15)) { credit in
                        FilmographyItemCard(credit: credit) {
                            onSelect(credit)
                        }
                    }
                }
            }
        }
    }
}

private struct FilmographyItemCard: View {
    let credit: PersonCredit
    var onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: credit.posterURL)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Text(credit.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
                    .frame(width: 110, alignment: .leading)
                
                if let character = credit.character, !character.isEmpty {
                    Text(character)
                        .font(.system(size: 11))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
                
                if let year = credit.year {
                    Text(year)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
    }
}
