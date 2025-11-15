# VibeWatch 🎬

A modern iOS app to discover, track, and enjoy your favorite movies and TV series with an innovative TikTok-style clips feature.

![iOS](https://img.shields.io/badge/iOS-17.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![SwiftUI](https://img.shields.io/badge/SwiftUI-✓-green.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## ✨ Features

### 🎬 Discovery
- **Mood-based recommendations** - Browse movies based on your current vibe
- **For You section** - Personalized content
- **Viral/Trending** - See what's hot right now
- **Beautiful carousel** - Swipe through top-rated movies
- **Real-time data** - Powered by TMDB API

### 📱 Clips (TikTok-Style)
- **Full-screen video player** - Immersive viewing experience
- **Vertical scrolling** - Swipe to next clip
- **Interactive buttons** - Like, comment, add to list, share
- **Scene highlights** - Best moments from movies and TV shows

### 📋 Lists
- **Create custom lists** - Organize your favorites
- **Smart filters** - View All, Movies only, or TV Series only
- **Track watched content** - Never lose track of what you've seen
- **Shareable lists** - Share with friends (coming soon)

### 👤 Profile & Auth
- **User authentication** - Secure login with Supabase
- **Personalized experience** - Your data synced across devices
- **Settings & preferences** - Customize your experience

## 🎨 Design

- **Dark theme** - Easy on the eyes
- **Liquid glass navigation** - Beautiful frosted glass bottom bar
- **Smooth animations** - Polished transitions throughout
- **Modern UI** - Clean, minimalist design
- **High-quality images** - Crisp movie posters and backdrops

## 🚀 Quick Start

### Prerequisites

- **Xcode 15.0+**
- **iOS 17.0+**
- **Swift 5.9+**

### Installation

1. **Clone the repository**
```bash
git clone https://github.com/yourusername/VibeWatch.git
cd VibeWatch
```

2. **Get API Keys**

#### TMDB (Required)
- Sign up at [themoviedb.org](https://www.themoviedb.org)
- Go to Settings → API
- Copy your API key (v3)

#### Supabase (Optional - for auth & lists)
- Create project at [supabase.com](https://supabase.com)
- Copy your Project URL and anon key

3. **Add Your API Keys**

Open `VibeWatchApp/Core/Network/TMDBService.swift` and add:
```swift
private let apiKey = "YOUR_TMDB_API_KEY"
```

For Supabase, edit `VibeWatchApp/Core/Supabase/SupabaseClient.swift`:
```swift
private let supabaseURL = "YOUR_SUPABASE_URL"
private let supabaseKey = "YOUR_SUPABASE_ANON_KEY"
```

4. **Open in Xcode**
```bash
open VibeWatchApp.xcodeproj
```

5. **Build & Run**
- Select an iPhone simulator
- Press **⌘R** or click the Run button
- Enjoy! 🎉

## 📱 Screenshots

*Coming soon - screenshots will be added after app is running*

## 🏗️ Architecture

**Pattern**: MVVM (Model-View-ViewModel)

```
┌──────────────┐
│  Views       │  SwiftUI UI components
└──────┬───────┘
       │
┌──────▼───────┐
│ ViewModels   │  @Published state, business logic
└──────┬───────┘
       │
┌──────▼───────┐
│  Services    │  API calls, data fetching
└──────┬───────┘
       │
┌──────▼───────┐
│   Models     │  Data structures
└──────────────┘
```

### Key Technologies

- **SwiftUI** - Modern declarative UI
- **Async/Await** - Structured concurrency
- **TMDB API** - Movie & TV data
- **Supabase** - Backend & authentication
- **AVKit** - Video playback
- **URLCache** - Smart caching strategy

### Performance Features

- **Rate limiting** - 40 requests per 10 seconds to TMDB
- **Response caching** - 50MB memory + 100MB disk
- **Lazy loading** - Efficient list rendering
- **Parallel requests** - Faster initial loads

## 📁 Project Structure

```
VibeWatchApp/
├── App/                      # App entry & main tab view
├── Core/
│   ├── Models/              # Data models (Movie, User, Clip, List)
│   ├── Network/             # API services (TMDB, OpenAI)
│   └── Supabase/            # Backend client
├── Features/
│   ├── Discovery/           # Main discovery page
│   ├── Clips/               # TikTok-style clips
│   ├── Lists/               # User lists
│   └── Profile/             # Auth & profile
├── Shared/
│   ├── Components/          # Reusable UI components
│   └── Extensions/          # Swift extensions & theme
└── Resources/               # Assets & config
```

## 🎯 Roadmap

### v1.0 (Current)
- ✅ Discovery page with TMDB integration
- ✅ Clips page structure
- ✅ Lists management
- ✅ Profile & authentication
- ✅ Liquid glass navigation

### v1.1 (Planned)
- [ ] Search functionality
- [ ] Comments on clips
- [ ] Social sharing
- [ ] Push notifications

### v2.0 (Future)
- [ ] Offline mode with local database
- [ ] AI-powered recommendations
- [ ] Watch party feature
- [ ] iPad optimization
- [ ] Widgets

## 🛠️ Development

### Build from Source

```bash
# Clone the repo
git clone https://github.com/yourusername/VibeWatch.git

# Open in Xcode
cd VibeWatch
open VibeWatchApp.xcodeproj

# Add your API keys (see Installation section)

# Build and run
# Select simulator and press ⌘R
```

### Running Tests

```bash
# In Xcode
⌘U or Product → Test
```

### Code Style

- Follow Swift naming conventions
- Use SwiftUI best practices
- Keep ViewModels testable
- Document complex logic

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **TMDB** - Movie and TV show data
- **Supabase** - Backend infrastructure
- **SwiftUI** - Powerful UI framework

## 📧 Contact

For questions or feedback, please open an issue on GitHub.

---

**Built with ❤️ using SwiftUI**

⭐️ If you like this project, please give it a star!
