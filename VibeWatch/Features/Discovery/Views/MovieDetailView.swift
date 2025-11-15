import SwiftUI

struct MovieDetailView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: MovieDetailViewModel
    
    init(movieId: Int) {
        _viewModel = StateObject(wrappedValue: MovieDetailViewModel(movieId: movieId))
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let movie = viewModel.movie {
                    MovieDetailHeaderView(
                        movie: movie,
                        onDismiss: { dismiss() }
                    )
                    
                    VStack(spacing: 24) {
                        MovieInfoSection(movie: movie)
                        
                        ActionButtonsSection()
                        
                        if let providers = viewModel.watchProviders {
                            WatchNowSection(providers: providers)
                        }
                        
                        if let trailer = viewModel.trailer {
                            TrailerSection(trailer: trailer)
                        }
                        
                        if !viewModel.mainCast.isEmpty || viewModel.director != nil {
                            MovieCreditsSection(
                                director: viewModel.director,
                                cast: viewModel.mainCast,
                                movie: movie
                            )
                        }
                        
                        if !viewModel.similarMovies.isEmpty {
                            SimilarMoviesSection(movies: viewModel.similarMovies)
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
            await viewModel.loadMovieDetails()
        }
    }
}

struct MovieDetailHeaderView: View {
    let movie: Movie
    let onDismiss: () -> Void
    
    var body: some View {
        ZStack(alignment: .top) {
            AsyncImageView(url: movie.backdropURL, contentMode: .fill)
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
                
                Text(movie.title)
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

struct MovieInfoSection: View {
    let movie: Movie
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let year = movie.year {
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                
                HStack(spacing: 4) {
                    Text("\(movie.ratingPercentage)%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                    Text("(\(movie.voteCount) ratings)")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            
            Text(movie.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if !movie.overview.isEmpty {
                Text(movie.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(4)
            }
        }
    }
}

struct ActionButtonsSection: View {
    @State private var isSaved = false
    @State private var isSeen = false
    @State private var isLiked: Bool?
    
    var body: some View {
        HStack(spacing: 12) {
            ActionButton(
                icon: isSaved ? "bookmark.fill" : "bookmark",
                title: "Save",
                isActive: isSaved
            ) {
                isSaved.toggle()
            }
            
            ActionButton(
                icon: isSeen ? "eye.fill" : "eye",
                title: "Seen",
                isActive: isSeen
            ) {
                isSeen.toggle()
            }
            
            ActionButton(
                icon: "hand.thumbsup.fill",
                title: "Like",
                isActive: isLiked == true
            ) {
                isLiked = isLiked == true ? nil : true
            }
            
            ActionButton(
                icon: "hand.thumbsdown.fill",
                title: "Dislike",
                isActive: isLiked == false
            ) {
                isLiked = isLiked == false ? nil : false
            }
        }
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundColor(isActive ? .theme.accentOrange : .theme.textPrimary)
            .background(isActive ? Color.theme.accentOrange.opacity(0.2) : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct WatchNowSection: View {
    let providers: CountryProviders
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Watch Now")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if let flatrate = providers.flatrate, !flatrate.isEmpty {
                ProviderGroup(title: "Stream", providers: flatrate)
            }
            
            if let rent = providers.rent, !rent.isEmpty {
                ProviderGroup(title: "Rent", providers: rent)
            }
            
            if let buy = providers.buy, !buy.isEmpty {
                ProviderGroup(title: "Buy", providers: buy)
            }
            
            Button {
                // TODO: Report issue
            } label: {
                HStack(spacing: 8) {
                    Text("Something wrong?")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                    Text("Let us know")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.theme.accentOrange)
                }
            }
        }
    }
}

struct ProviderGroup: View {
    let title: String
    let providers: [Provider]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 60), spacing: 12)
            ], spacing: 12) {
                ForEach(providers) { provider in
                    AsyncImageView(url: provider.logoURL, contentMode: .fit)
                        .frame(width: 60, height: 60)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct TrailerSection: View {
    let trailer: Video
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trailer")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            AsyncImageView(url: trailer.thumbnailURL, contentMode: .fill)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    Button {
                        // TODO: Play trailer
                        if let url = trailer.youtubeURL {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                            .shadow(radius: 10)
                    }
                }
        }
    }
}

struct MovieCreditsSection: View {
    let director: Crew?
    let cast: [Cast]
    let movie: Movie
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Information")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            VStack(alignment: .leading, spacing: 12) {
                if movie.ratingPercentage > 0 {
                    InfoRow(title: "Rating", value: "\(movie.ratingPercentage)%")
                }
                
                if let genres = movie.genres, !genres.isEmpty {
                    InfoRow(title: "Genres", value: genres.map { $0.name }.joined(separator: ", "))
                }
                
                if let runtime = movie.formattedRuntime {
                    InfoRow(title: "Runtime", value: runtime)
                }
                
                if let countries = movie.productionCountries, !countries.isEmpty {
                    InfoRow(title: "Country", value: countries.first?.name ?? "")
                }
                
                if let director = director {
                    InfoRow(title: "Director", value: director.name)
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

struct InfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14))
                .foregroundColor(.theme.textPrimary)
            
            Spacer()
        }
    }
}

struct CastMemberCard: View {
    let actor: Cast
    
    var body: some View {
        VStack(spacing: 8) {
            AsyncImageView(url: actor.profileURL, contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            
            VStack(spacing: 2) {
                Text(actor.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                
                Text(actor.character)
                    .font(.system(size: 10))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 80)
        }
    }
}

struct SimilarMoviesSection: View {
    let movies: [Movie]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People who liked this also liked")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(movies) { movie in
                        MediaCard(movie: movie)
                    }
                }
            }
        }
    }
}
