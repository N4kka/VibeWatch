# VibeWatch Setup Guide

## Quick Start

Follow these steps to get VibeWatch running on your machine.

### 1. Prerequisites

- macOS 13.0 or later
- Xcode 15.0 or later
- iOS 16.0+ device or simulator
- Active internet connection

### 2. Get API Keys

#### TMDB API Key (Required)

1. Go to [themoviedb.org](https://www.themoviedb.org)
2. Create a free account
3. Navigate to Settings → API
4. Request an API key (choose "Developer" option)
5. Copy your API v3 key

#### Supabase Setup (Required)

1. Go to [supabase.com](https://supabase.com)
2. Create a new project
3. Wait for project initialization (2-3 minutes)
4. Go to Project Settings → API
5. Copy your:
   - Project URL
   - Anon/Public key

#### Database Setup

1. In your Supabase project, go to SQL Editor
2. Copy the SQL from `README.md` (Database Schema section)
3. Run the SQL commands to create tables and policies

#### OpenAI API Key (Optional)

1. Go to [platform.openai.com](https://platform.openai.com)
2. Create an account
3. Navigate to API Keys
4. Create a new secret key
5. Copy the key (you won't see it again!)

### 3. Configure the App

#### Option A: Using Config.swift (Recommended)

1. Navigate to `VibeWatch/Core/Network/`
2. Copy `Config.swift.template` to `Config.swift`:
   ```bash
   cd VibeWatch/Core/Network/
   cp Config.swift.template Config.swift
   ```
3. Open `Config.swift` in Xcode
4. Replace placeholders with your actual API keys:
   ```swift
   static let tmdbAPIKey = "your_actual_tmdb_key"
   static let supabaseURL = "https://xxxxx.supabase.co"
   static let supabaseAnonKey = "your_actual_supabase_key"
   static let openAIAPIKey = "your_actual_openai_key" // Optional
   ```

#### Option B: Direct Configuration

If you skipped Option A, edit these files directly:

1. **TMDBService.swift**
   ```swift
   private let apiKey = "YOUR_TMDB_API_KEY"
   ```

2. **SupabaseClient.swift**
   ```swift
   private let supabaseURL = "YOUR_SUPABASE_URL"
   private let supabaseKey = "YOUR_SUPABASE_ANON_KEY"
   ```

3. **OpenAIService.swift** (Optional)
   ```swift
   private let apiKey = "YOUR_OPENAI_API_KEY"
   ```

### 4. Install Dependencies

The app uses Swift Package Manager for dependencies:

1. Open `VibeWatch.xcodeproj` in Xcode
2. Xcode will automatically resolve packages
3. Wait for "Resolving Package Graph" to complete
4. Build the project (⌘B) to download dependencies

### 5. Build & Run

1. Select a simulator or connected device
2. Press ⌘R or click the Run button
3. The app will launch with the Discovery page

## Testing the Setup

### Test TMDB Integration

1. Launch the app
2. You should see movies/shows on the Discovery page
3. If you see "No content" or errors, check your TMDB API key

### Test Supabase Integration

1. Tap the profile icon (top right)
2. Try to create an account
3. If authentication fails, verify:
   - Supabase URL is correct
   - Anon key is correct
   - Database tables are created

### Test Navigation

1. Tap "Clips" in the bottom navigation
2. Tap "Lists" in the bottom navigation
3. All pages should load without crashes

## Troubleshooting

### "Invalid API Key" Error

- Double-check your TMDB API key
- Make sure you copied the v3 API key (not v4 Bearer token)
- Verify no extra spaces in the key

### "Supabase Not Configured" Error

- Ensure Supabase URL starts with `https://`
- Verify the anon key is the public key, not service role key
- Check that the Supabase project is active

### Build Errors

1. Clean build folder: ⌘⇧K
2. Delete derived data:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData
   ```
3. Restart Xcode

### No Content Loading

- Check internet connection
- Verify API keys are correct
- Check Xcode console for error messages
- Test API keys with curl:
  ```bash
  curl "https://api.themoviedb.org/3/movie/popular?api_key=YOUR_KEY"
  ```

### Supabase Connection Issues

1. Verify project URL in browser
2. Check if project is paused (free tier pauses after inactivity)
3. Verify RLS policies are created correctly

## Project Structure Overview

```
VibeWatch/
├── App/                    # App entry point & main tab view
├── Core/                   # Core services and models
│   ├── Network/           # API services (TMDB, OpenAI)
│   ├── Supabase/          # Supabase client
│   └── Models/            # Data models
├── Features/              # Feature modules
│   ├── Discovery/         # Main discovery page
│   ├── Clips/             # TikTok-style clips
│   ├── Lists/             # User lists
│   └── Profile/           # User profile & auth
├── Shared/                # Shared components
│   ├── Components/        # Reusable UI components
│   └── Extensions/        # Swift extensions
└── Resources/             # Assets & config files
```

## Next Steps

Once the app is running:

1. **Explore Discovery**: Browse movies and TV shows
2. **Create Lists**: Save your favorites
3. **Set Up Clips**: Add video URLs to the Clips table in Supabase
4. **Customize**: Modify the UI to match your preferences

## Development Tips

### Xcode Shortcuts

- ⌘R - Run
- ⌘B - Build
- ⌘⇧K - Clean Build
- ⌘. - Stop running
- ⌃I - Fix indentation

### Hot Reload

SwiftUI supports live previews:
1. Open any View file
2. Click "Resume" in the preview canvas (right side)
3. Changes appear instantly without rebuilding

### Debugging

- Add breakpoints by clicking line numbers
- Use `print()` for quick debugging
- Check Xcode console for error messages

## Support

For issues or questions:

1. Check the README.md
2. Review Xcode console logs
3. Verify API keys and credentials
4. Check TMDB API documentation: [developers.themoviedb.org](https://developers.themoviedb.org)
5. Check Supabase docs: [supabase.com/docs](https://supabase.com/docs)

## Security Notes

⚠️ **Important**: 

- Never commit API keys to version control
- `Config.swift` is in `.gitignore` by default
- Don't share your Supabase service role key
- Use environment variables in production

---

**You're all set!** Enjoy building with VibeWatch 🎬
