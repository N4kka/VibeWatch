import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var selectedMovie: Movie?
    @State private var selectedMediaType: MediaType = .movie
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            if isLoading {
                SplashScreen()
                    .transition(.opacity)
                    .onAppear {
                        // Hide splash screen after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                            withAnimation(.easeOut(duration: 0.5)) {
                                isLoading = false
                            }
                        }
                    }
            } else {
                NavigationStack {
                    ZStack(alignment: .bottom) {
                        TabView(selection: $selectedTab) {
                            DiscoveryView(selectedMovie: $selectedMovie, selectedMediaType: $selectedMediaType)
                            .tag(0)
                    
                    ClipsView()
                        .tag(1)
                    
                    ListsView()
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                
                // Hide bottom bar when on Clips tab
                if selectedTab != 1 {
                    LiquidGlassBottomBar(selectedTab: $selectedTab)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                    }
                    .background(Color.theme.background.ignoresSafeArea())
                    .navigationBarHidden(true)
                    .navigationDestination(item: $selectedMovie) { movie in
                        if selectedMediaType == .movie {
                            MovieDetailView(movieId: movie.id)
                        } else {
                            TVShowDetailView(tvShowId: movie.id)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

struct LiquidGlassBottomBar: View {
    @Binding var selectedTab: Int
    
    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(
                icon: "house.fill",
                title: "tab.discovery".localized,
                isSelected: selectedTab == 0
            ) {
                selectedTab = 0
            }
            
            TabBarButton(
                icon: "play.rectangle.fill",
                title: "tab.clips".localized,
                isSelected: selectedTab == 1
            ) {
                selectedTab = 1
            }
            
            TabBarButton(
                icon: "list.bullet",
                title: "tab.lists".localized,
                isSelected: selectedTab == 2
            ) {
                selectedTab = 2
            }
        }
        .frame(height: 60)
        .liquidGlass()
        .clipShape(RoundedRectangle(cornerRadius: 30))
    }
}

struct TabBarButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? .theme.accentOrange : .theme.textSecondary)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
