import SwiftUI

struct TVShowDetailView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: TVShowDetailViewModel
    
    init(tvShowId: Int) {
        _viewModel = StateObject(wrappedValue: TVShowDetailViewModel(tvShowId: tvShowId))
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let tvShow = viewModel.tvShow {
                    TVShowDetailHeaderView(
                        tvShow: tvShow,
                        onDismiss: { dismiss() }
                    )
                    
                    VStack(spacing: 24) {
                        TVShowInfoSection(tvShow: tvShow)
                        
                        ActionButtonsSection()
                        
                        if let providers = viewModel.watchProviders {
                            WatchNowSection(providers: providers)
                        }
                        
                        if let trailer = viewModel.trailer {
                            TrailerSection(trailer: trailer)
                        }
                        
                        if !viewModel.mainCast.isEmpty {
                            TVShowCreditsSection(
                                cast: viewModel.mainCast,
                                tvShow: tvShow
                            )
                        }
                        
                        if !viewModel.similarShows.isEmpty {
                            SimilarTVShowsSection(tvShows: viewModel.similarShows)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                }
            }
        }
        .background(Color.theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await viewModel.loadTVShowDetails()
        }
    }
}

struct TVShowDetailHeaderView: View {
    let tvShow: TVShow
    let onDismiss: () -> Void
    
    var body: some View {
        ZStack(alignment: .top) {
            AsyncImageView(url: tvShow.backdropURL, contentMode: .fill)
                .frame(height: 300)
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
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Text(tvShow.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button {
                        // TODO: Search
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    
                    Button {
                        // TODO: Share
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 50)
        }
        .frame(height: 300)
    }
}

struct TVShowInfoSection: View {
    let tvShow: TVShow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let year = tvShow.year {
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                
                HStack(spacing: 4) {
                    Text("\(Int(tvShow.voteAverage * 10))%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                    Text("(\(tvShow.voteCount) ratings)")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            
            Text(tvShow.name)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if !tvShow.overview.isEmpty {
                Text(tvShow.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(4)
            }
        }
    }
}

struct TVShowCreditsSection: View {
    let cast: [Cast]
    let tvShow: TVShow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Information")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(title: "Rating", value: "\(Int(tvShow.voteAverage * 10))%")
                
                if let genres = tvShow.genres, !genres.isEmpty {
                    InfoRow(title: "Genres", value: genres.map { $0.name }.joined(separator: ", "))
                }
                
                if let countries = tvShow.productionCountries, !countries.isEmpty {
                    InfoRow(title: "Country", value: countries.first?.name ?? "")
                }
            }
            
            if !cast.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cast")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cast) { actor in
                                CastMemberCard(actor: actor)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SimilarTVShowsSection: View {
    let tvShows: [TVShow]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People who liked this also liked")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(tvShows) { show in
                        TVShowCard(tvShow: show)
                    }
                }
            }
        }
    }
}

struct TVShowCard: View {
    let tvShow: TVShow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImageView(url: tvShow.posterURL, contentMode: .fill)
                .frame(width: 140, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Text(tvShow.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)
                .frame(width: 140, alignment: .leading)
            
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.theme.accentOrange)
                Text(tvShow.rating)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }
}
