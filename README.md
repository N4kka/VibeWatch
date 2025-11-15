# VibeWatch

A modern iOS app to discover, track, and enjoy your favorite movies and TV series with an innovative clips feature.

## Features

### 🎬 Discovery
- Mood-based movie recommendations
- "For You" personalized content
- Viral/Trending movies and shows
- Beautiful carousel interface
- Search functionality

### 📱 Clips
- TikTok-style full-screen video player
- Short scenes from movies and TV shows
- Like, comment, and share functionality
- Add clips to your lists

### 📋 Lists
- Create and manage custom lists
- Filter by All, Movies, or TV Series
- Track watched content
- Share lists with friends

### 👤 Profile
- User authentication
- Personalized recommendations
- Manage streaming service preferences
- Settings and notifications

## Tech Stack

- **SwiftUI** - Modern declarative UI framework
- **TMDB API** - Movie and TV show data
- **Supabase** - Authentication and database
- **OpenAI API** - AI-powered clip descriptions
- **AVKit** - Video playback

## Architecture

The app follows **MVVM (Model-View-ViewModel)** architecture with:

- **Features-based structure** - Organized by app features
- **Repository pattern** - Centralized data management
- **Offline-first** - Local caching with URLCache
- **Rate limiting** - Smart API request throttling (40 req/10s)

## Project Structure

```
VibeWatch/
├── App/
│   ├── VibeWatchApp.swift
│   └── MainTabView.swift
├── Core/
│   ├── Network/
│   │   ├── TMDBService.swift
│   │   └── OpenAIService.swift
│   ├── Database/
│   │   └── CacheManager.swift
│   ├── Supabase/
│   │   └── SupabaseClient.swift
│   └── Models/
│       ├── User.swift
│       ├── Movie.swift
│       ├── Clip.swift
│       └── MediaList.swift
├── Features/
│   ├── Discovery/
│   │   ├── Views/
│   │   └── ViewModels/
│   ├── Clips/
│   │   ├── Views/
│   │   └── ViewModels/
│   ├── Lists/
│   │   ├── Views/
│   │   └── ViewModels/
│   └── Profile/
│       ├── Views/
│       └── ViewModels/
├── Shared/
│   ├── Components/
│   │   ├── AsyncImageView.swift
│   │   └── LiquidGlassView.swift
│   ├── Extensions/
│   │   └── Color+Theme.swift
│   └── Utilities/
└── Resources/
    └── Info.plist
```

## Setup

### Prerequisites
- Xcode 15.0+
- iOS 16.0+
- Swift 5.9+

### API Keys Required

1. **TMDB API Key**
   - Sign up at [themoviedb.org](https://www.themoviedb.org)
   - Get your API key from account settings
   - Add to `TMDBService.swift`:
     ```swift
     private let apiKey = "YOUR_TMDB_API_KEY"
     ```

2. **Supabase Credentials**
   - Create project at [supabase.com](https://supabase.com)
   - Get URL and anon key from project settings
   - Add to `SupabaseClient.swift`:
     ```swift
     private let supabaseURL = "YOUR_SUPABASE_URL"
     private let supabaseKey = "YOUR_SUPABASE_KEY"
     ```

3. **OpenAI API Key** (Optional - for AI clip descriptions)
   - Get key from [platform.openai.com](https://platform.openai.com)
   - Add to `OpenAIService.swift`:
     ```swift
     private let apiKey = "YOUR_OPENAI_API_KEY"
     ```

### Database Schema (Supabase)

Run these SQL commands in your Supabase SQL editor:

```sql
-- Users table (extends Supabase auth.users)
CREATE TABLE users (
  id UUID REFERENCES auth.users PRIMARY KEY,
  email TEXT NOT NULL,
  display_name TEXT,
  avatar_url TEXT,
  selected_providers TEXT[],
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Lists table
CREATE TABLE lists (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  visibility TEXT NOT NULL DEFAULT 'private',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- List items table
CREATE TABLE list_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id UUID REFERENCES lists(id) ON DELETE CASCADE,
  tmdb_id INTEGER NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('movie', 'tv')),
  position INTEGER NOT NULL,
  notes TEXT,
  watched BOOLEAN DEFAULT false,
  added_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Clips table
CREATE TABLE clips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  movie_id INTEGER,
  tv_show_id INTEGER,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  video_url TEXT NOT NULL,
  thumbnail_url TEXT,
  duration INTEGER NOT NULL,
  likes INTEGER DEFAULT 0,
  comments INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable Row Level Security
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE list_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE clips ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Users can view own data" ON users FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own data" ON users FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Users can view own lists" ON lists FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create own lists" ON lists FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own lists" ON lists FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own lists" ON lists FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "Anyone can view clips" ON clips FOR SELECT TO authenticated USING (true);
```

### Installation

1. Clone the repository
2. Open `VibeWatch.xcodeproj` in Xcode
3. Add your API keys (see above)
4. Build and run (⌘R)

## Design System

Based on the CineStream design system:

- **Colors**:
  - Background: `#0c0d10` (deep dark gray)
  - Accent: `#fb7f33` (vibrant orange)
  - Text Primary: `#ffffff`
  - Text Secondary: `#b0b0b0`

- **Typography**: San Francisco (system font)
  - Hero: Large, bold
  - Headlines: Medium-large, 600-700 weight
  - Body: Medium, 400 weight

- **Components**:
  - Liquid glass bottom navigation
  - Gradient overlays
  - Rounded corners (12px)
  - Card-based layouts

## Roadmap

- [ ] Add TMDB API key configuration
- [ ] Complete Supabase integration
- [ ] Implement OpenAI clip generation
- [ ] Add video caching
- [ ] Implement search functionality
- [ ] Add social features (comments, sharing)
- [ ] Offline mode improvements
- [ ] Push notifications
- [ ] Analytics integration

## Contributing

This is a personal project, but suggestions and feedback are welcome!

## License

MIT License - See LICENSE file for details

---

Built with ❤️ using SwiftUI
