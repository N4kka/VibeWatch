import SwiftUI

struct DiscoveryView: View {
    @StateObject private var viewModel = DiscoveryViewModel()
    @State private var showProfile = false
    @State private var searchText = ""
    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 32) {
                    Color.clear
                        .frame(height: 60)
                    
                    if !viewModel.moodMovies.isEmpty {
                        MoodCarouselSection(movies: viewModel.moodMovies)
                    }
                    
                    if !viewModel.forYouMovies.isEmpty {
                        MediaSection(
                            title: "For You",
                            items: viewModel.forYouMovies,
                            type: .movie
                        )
                    }
                    
                    if !viewModel.viralMovies.isEmpty {
                        MediaSection(
                            title: "Viral Now",
                            items: viewModel.viralMovies,
                            type: .movie
                        )
                    }
                    
                    if !viewModel.forYouTVShows.isEmpty {
                        MediaSection(
                            title: "TV Shows For You",
                            items: viewModel.forYouTVShows,
                            type: .tv
                        )
                    }
                    
                    Color.clear
                        .frame(height: 80)
                }
            }
            .refreshable {
                await viewModel.loadContent()
            }
            
            DiscoveryHeaderView(
                searchText: $searchText,
                onProfileTap: { showProfile = true }
            )
        }
        .background(Color.theme.background.ignoresSafeArea())
        .task {
            await viewModel.loadContent()
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
    }
}

struct DiscoveryHeaderView: View {
    @Binding var searchText: String
    let onProfileTap: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                
                Text("VibeWatch")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    // TODO: Implement search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                
                Button(action: onProfileTap) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.theme.textSecondary)
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
    @State private var currentIndex = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Based on Your Mood")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
            
            TabView(selection: $currentIndex) {
                ForEach(Array(movies.prefix(5).enumerated()), id: \.element.id) { index, movie in
                    MoodCarouselCard(movie: movie)
                        .tag(index)
                }
            }
            .frame(height: 500)
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }
}

struct MoodCarouselCard: View {
    let movie: Movie
    
    var body: some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(url: movie.backdropURL, contentMode: .fill)
                .frame(height: 500)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [
                            .clear,
                            .clear,
                            Color.black.opacity(0.6),
                            Color.black.opacity(0.9)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
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
                .font(.system(size: 14))
                
                Text(movie.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(3)
                
                HStack(spacing: 12) {
                    Button {
                        // TODO: Add to list
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Add to List")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.theme.accentOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 25))
                    }
                    
                    Button {
                        // TODO: View details
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }
}

struct MediaSection: View {
    let title: String
    let items: [Movie]
    let type: MediaType
    
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
