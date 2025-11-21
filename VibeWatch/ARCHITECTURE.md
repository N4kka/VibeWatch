# VibeWatch Architecture

## Overview

VibeWatch follows a clean, modular architecture designed for scalability and maintainability.

## Architecture Pattern

**MVVM (Model-View-ViewModel)** with Repository Pattern

```
┌─────────────────────────────────────────────────────────┐
│                         View Layer                       │
│  (SwiftUI Views - Discovery, Clips, Lists, Profile)    │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    ViewModel Layer                       │
│     (Business Logic - Data transformation, State)       │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                   Service Layer                          │
│  (API Calls - TMDB, Supabase, OpenAI)                  │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    Model Layer                           │
│        (Data Models - Movie, User, List, Clip)         │
└─────────────────────────────────────────────────────────┘
```

## App Flow

### 1. Discovery Flow

```
User Opens App
      │
      ▼
MainTabView (Liquid Glass Navigation)
      │
      ▼
DiscoveryView
      │
      ├─── DiscoveryViewModel.loadContent()
      │         │
      │         ▼
      │    TMDBService
      │         │
      │         ├─── getTrendingMovies() → Mood Carousel
      │         ├─── getPopularMovies() → For You
      │         └─── getTrendingMovies() → Viral
      │
      └─── Display Sections:
            ├─── MoodCarouselSection (5 movies)
            ├─── MediaSection (For You)
            └─── MediaSection (Viral)
```

### 2. Clips Flow

```
User Taps "Clips" Tab
      │
      ▼
ClipsView
      │
      ├─── ClipsViewModel.loadClips()
      │         │
      │         ▼
      │    SupabaseClient.getClips()
      │         │
      │         └─── Returns [Clip]
      │
      └─── Display:
            └─── TabView (Vertical Scroll)
                  └─── ClipPlayerView
                        ├─── AVPlayer (Video)
                        ├─── Action Buttons
                        │     ├─── Like
                        │     ├─── Comment
                        │     ├─── Add to List
                        │     └─── Share
                        └─── Title + Description
```

### 3. Lists Flow

```
User Taps "Lists" Tab
      │
      ▼
ListsView
      │
      ├─── ListsViewModel.loadLists()
      │         │
      │         ▼
      │    SupabaseClient.getLists()
      │         │
      │         └─── Returns [MediaList]
      │
      └─── Display:
            ├─── Filter Chips (All/Movies/TV)
            └─── Grid of ListCards
```

### 4. Authentication Flow

```
User Taps Profile Avatar
      │
      ▼
ProfileView
      │
      ├─── Check AppState.isAuthenticated
      │         │
      │         ├─── Yes → Show Profile
      │         └─── No → Show Login/Signup Buttons
      │
      └─── User Taps "Sign In"
            │
            ▼
       LoginView
            │
            ├─── Enter Email/Password
            └─── handleAuth()
                  │
                  ▼
            SupabaseClient.signIn()
                  │
                  └─── Update AppState
```

## Data Flow

### 1. API Request Flow (TMDB)

```
View Request
     │
     ▼
ViewModel
     │
     ▼
TMDBService
     │
     ├─── Rate Limiting (40 req/10s)
     │
     ├─── Check URLCache
     │     ├─── Hit → Return Cached
     │     └─── Miss → Continue
     │
     ├─── Build URL with Query Params
     │
     ├─── Execute URLSession Request
     │
     ├─── Decode JSON Response
     │
     └─── Return Model
           │
           ▼
      ViewModel Updates @Published Properties
           │
           ▼
      View Auto-Updates (SwiftUI)
```

### 2. Caching Strategy

```
┌──────────────────────────────────────┐
│         URLCache (50MB Memory)       │
│                                      │
│  - Search Results: 30s TTL          │
│  - Movie Details: 1h TTL            │
│  - Images: Permanent                │
└──────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│    Disk Cache (100MB Disk)          │
│                                      │
│  - Longer term storage               │
│  - Survives app restarts             │
└──────────────────────────────────────┘
```

### 3. Authentication Flow (Supabase)

```
User Action (Login/Signup)
     │
     ▼
SupabaseClient
     │
     ├─── signUp() or signIn()
     │
     ▼
Supabase Auth API
     │
     ├─── Validate Credentials
     │
     ├─── Return Session + User
     │
     └─── Store Session Token
           │
           ▼
      AppState.isAuthenticated = true
           │
           ▼
      App Updates UI
```

## Component Hierarchy

```
VibeWatchApp (@main)
│
└─── MainTabView
      │
      ├─── DiscoveryView
      │     ├─── DiscoveryHeaderView
      │     │     ├─── Logo + App Name
      │     │     ├─── Search Button
      │     │     └─── Profile Avatar
      │     │
      │     ├─── MoodCarouselSection
      │     │     └─── MoodCarouselCard (x5)
      │     │
      │     └─── MediaSection (x3)
      │           └─── MediaCard (ScrollView)
      │
      ├─── ClipsView
      │     └─── TabView (Vertical)
      │           └─── ClipPlayerView
      │                 ├─── VideoPlayer (AVKit)
      │                 ├─── ClipActionButton (x4)
      │                 └─── Title + Description
      │
      ├─── ListsView
      │     ├─── Header with Create Button
      │     ├─── FilterChips (All/Movies/TV)
      │     └─── LazyVGrid
      │           └─── ListCard
      │
      └─── LiquidGlassBottomBar
            └─── TabBarButton (x3)
```

## Design Patterns

### 1. MVVM Pattern

**View**: Pure SwiftUI, no business logic
```swift
struct DiscoveryView: View {
    @StateObject private var viewModel = DiscoveryViewModel()
    
    var body: some View {
        // UI only
    }
}
```

**ViewModel**: Business logic, state management
```swift
@MainActor
class DiscoveryViewModel: ObservableObject {
    @Published var movies: [Movie] = []
    
    func loadContent() async {
        // Business logic
    }
}
```

**Model**: Data structures
```swift
struct Movie: Codable {
    let id: Int
    let title: String
    // ...
}
```

### 2. Singleton Pattern (Services)

```swift
class TMDBService {
    static let shared = TMDBService()
    private init() {}
}

class SupabaseClient {
    static let shared = SupabaseClient()
    private init() {}
}
```

### 3. Dependency Injection (via Environment)

```swift
@main
struct VibeWatchApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
        }
    }
}
```

### 4. Observer Pattern (@Published)

```swift
class ViewModel: ObservableObject {
    @Published var data: [Item] = []
    // View automatically updates when data changes
}
```

## Key Features Implementation

### Liquid Glass Effect

```swift
struct LiquidGlassView: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}
```

### Rate Limiting

```swift
private let rateLimitInterval: TimeInterval = 0.25 // 4 req/s

private func rateLimit() async {
    if let lastTime = lastRequestTime {
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed < rateLimitInterval {
            Thread.sleep(forTimeInterval: rateLimitInterval - elapsed)
        }
    }
    lastRequestTime = Date()
}
```

### Async/Await Pattern

```swift
func loadContent() async {
    do {
        async let movies = tmdbService.getPopularMovies()
        async let shows = tmdbService.getPopularTVShows()
        
        let (m, s) = try await (movies, shows)
        
        self.movies = m.results
        self.shows = s.results
    } catch {
        // Handle error
    }
}
```

## Performance Optimizations

### 1. Lazy Loading
- `LazyVGrid` and `LazyVStack` for lists
- Images loaded on-demand with `AsyncImage`

### 2. Caching
- URLCache for API responses
- Image caching via `AsyncImage`

### 3. Rate Limiting
- 40 requests per 10 seconds to TMDB
- Exponential backoff on errors

### 4. Parallel Requests
- `async let` for concurrent API calls
- Faster initial load times

## Security Considerations

### 1. API Keys
- Never hardcode in source
- Use `Config.swift` (gitignored)
- Environment variables in production

### 2. Supabase RLS
- Row Level Security enabled
- Users can only access own data
- Public clips for all authenticated users

### 3. Data Validation
- Input validation on forms
- Type-safe models with `Codable`
- Error handling on all API calls

## Testing Strategy

### Unit Tests
- ViewModels business logic
- Service layer API calls
- Model transformations

### UI Tests
- Navigation flows
- Form inputs
- Error states

### Integration Tests
- API integration
- Database operations
- Authentication flows

## Future Enhancements

### Phase 2
- [ ] Offline mode with local SQLite
- [ ] Background video download
- [ ] Push notifications
- [ ] Social features (friends, comments)

### Phase 3
- [ ] AI recommendations
- [ ] Watch party feature
- [ ] Advanced search filters
- [ ] Multi-profile support

### Phase 4
- [ ] iPad optimization
- [ ] macOS app (Catalyst)
- [ ] Apple TV app
- [ ] Widgets

---

**Architecture Version**: 1.0  
**Last Updated**: November 2025
