import SwiftUI

struct DiscoveryView: View {
    @StateObject private var viewModel = DiscoveryViewModel()
    @EnvironmentObject var appState: AppState
    @ObservedObject var localizationManager = LocalizationManager.shared
    @State private var showProfile = false
    @State private var showSearch = false
    @Binding var selectedMovie: Movie?
    @Binding var selectedMediaType: MediaType
    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 32) {
                    Color.clear
                        .frame(height: 60)
                    
                    if !viewModel.moodMovies.isEmpty {
                        MoodCarouselSection(movies: viewModel.moodMovies) { movie in
                            selectedMovie = movie
                            selectedMediaType = .movie
                        }
                    }
                    
                    if !viewModel.forYouMovies.isEmpty {
                        MediaSection(
                            title: "discovery.forYou".localized,
                            items: viewModel.forYouMovies,
                            type: .movie
                        ) { movie in
                            selectedMovie = movie
                            selectedMediaType = .movie
                        }
                    }
                    
                    if !viewModel.viralMovies.isEmpty {
                        MediaSection(
                            title: "discovery.trending".localized,
                            items: viewModel.viralMovies,
                            type: .movie
                        ) { movie in
                            selectedMovie = movie
                            selectedMediaType = .movie
                        }
                    }
                    
                    if !viewModel.forYouTVShows.isEmpty {
                        MediaSection(
                            title: "discovery.tvShows".localized,
                            items: viewModel.forYouTVShows,
                            type: .tv
                        ) { movie in
                            selectedMovie = movie
                            selectedMediaType = .tv
                        }
                    }
                    
                    Color.clear
                        .frame(height: 80)
                }
            }
            .refreshable {
                await viewModel.loadContent()
            }
            
            DiscoveryHeaderView(
                onSearchTap: { showSearch = true },
                onProfileTap: { showProfile = true },
                avatarURL: appState.currentUser?.avatarURL
            )
        }
        .background(Color.theme.background.ignoresSafeArea())
        .task {
            await viewModel.loadContent()
        }
        .onChange(of: localizationManager.localeDidChange) { _ in
            // Reload content when language/country changes
            Task {
                await viewModel.loadContent(forceRefresh: true)
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView()
        }
        .toast(isShowing: $appState.showSuccessToast, message: appState.toastMessage, type: .success)
        .toast(isShowing: $appState.showErrorToast, message: appState.toastMessage, type: .error)
    }
}

struct DiscoveryHeaderView: View {
    let onSearchTap: () -> Void
    let onProfileTap: () -> Void
    let avatarURL: String?
    
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image("logo_56x56")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                
                Text("discovery.vibeWatch".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                
                Button(action: onProfileTap) {
                    if let avatarURL = avatarURL, let url = URL(string: avatarURL) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.theme.textSecondary)
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Color.theme.navigationBackground
                .ignoresSafeArea()
                .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        }
    }
}

struct MoodCarouselSection: View {
    let movies: [Movie]
    let onMovieTap: (Movie) -> Void
    @State private var currentIndex = 0
    @ObservedObject var localizationManager = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("discovery.basedOnMood".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            
            TabView(selection: $currentIndex) {
                ForEach(Array(movies.prefix(5).enumerated()), id: \.element.id) { index, movie in
                    MoodCarouselCard(movie: movie) {
                        onMovieTap(movie)
                    }
                    .tag(index)
                }
            }
            .frame(height: 500)
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            HStack(spacing: 6) {
                ForEach(0..<min(5, movies.count), id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? Color.theme.accentOrange : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
    }
}

struct MoodCarouselCard: View {
    let movie: Movie
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    AsyncImageView(url: movie.backdropURL, contentMode: .fill)
                        .frame(width: geometry.size.width, height: 500)
                        .clipped()
                        .overlay {
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.black.opacity(0.3),
                                    Color.black.opacity(0.7),
                                    Color.black.opacity(0.95)
                                ],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                        }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(movie.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.theme.accentOrange)
                                Text(movie.rating)
                                    .foregroundColor(.white)
                            }
                            
                            if let year = movie.year {
                                Text(year)
                                    .foregroundColor(.theme.textSecondary)
                            }
                        }
                        .font(.system(size: 13))
                        
                        Text(movie.overview)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .frame(height: 500)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 20)
    }
}

struct MediaSection: View {
    let title: String
    let items: [Movie]
    let type: MediaType
    let onMovieTap: (Movie) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { movie in
                        MediaCard(movie: movie)
                            .onTapGesture {
                                onMovieTap(movie)
                            }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct MediaCard: View {
    let movie: Movie
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImageView(url: movie.posterURL, contentMode: .fill)
                .frame(width: 140, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Text(movie.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)
                .frame(width: 140, alignment: .leading)
            
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.theme.accentOrange)
                Text(movie.rating)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }
}

#Preview {
    MainTabView()
}
