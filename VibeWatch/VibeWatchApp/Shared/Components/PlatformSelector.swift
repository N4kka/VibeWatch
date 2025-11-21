import SwiftUI

struct PlatformSelector: View {
    @Binding var selectedPlatforms: Set<StreamingPlatform>
    @State private var showSelector = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Trigger Button
            Button {
                showSelector.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 16, weight: .semibold))
                    
                    Text(selectedPlatforms.isEmpty ? "All Platforms" : "\(selectedPlatforms.count) Selected")
                        .font(.system(size: 14, weight: .medium))
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $showSelector) {
            PlatformSelectorSheet(selectedPlatforms: $selectedPlatforms)
        }
    }
}

struct PlatformSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedPlatforms: Set<StreamingPlatform>
    
    let platforms = StreamingPlatform.allCases
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Select All / Clear All
                    HStack {
                        Button {
                            if selectedPlatforms.count == platforms.count {
                                selectedPlatforms.removeAll()
                            } else {
                                selectedPlatforms = Set(platforms)
                            }
                        } label: {
                            Text(selectedPlatforms.count == platforms.count ? "Clear All" : "Select All")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.theme.accentOrange)
                        }
                        
                        Spacer()
                        
                        Text("\(selectedPlatforms.count) of 30 selected")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    
                    // Platform Grid
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(platforms) { platform in
                            PlatformCard(
                                platform: platform,
                                isSelected: selectedPlatforms.contains(platform)
                            ) {
                                if selectedPlatforms.contains(platform) {
                                    selectedPlatforms.remove(platform)
                                } else {
                                    selectedPlatforms.insert(platform)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .background(Color.theme.background)
            .navigationTitle("Streaming Platforms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.theme.accentOrange)
                }
            }
        }
    }
}

struct PlatformCard: View {
    let platform: StreamingPlatform
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(platform.color)
                        .frame(height: 80)
                    
                    Image(systemName: platform.icon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Text(platform.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.theme.accentOrange)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 20))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
    }
}

enum StreamingPlatform: String, CaseIterable, Identifiable, Codable {
    case netflix = "Netflix"
    case disney = "Disney+"
    case prime = "Prime Video"
    case hbo = "HBO Max"
    case apple = "Apple TV+"
    case paramount = "Paramount+"
    case hulu = "Hulu"
    case peacock = "Peacock"
    case showtime = "Showtime"
    case max = "Max"
    case pluto = "Pluto TV"
    case tubi = "Tubi"
    case crunchyroll = "Crunchyroll"
    case discoveryPlus = "Discovery+"
    case starz = "Starz"
    case mgmPlus = "MGM+"
    case amc = "AMC+"
    case mubi = "MUBI"
    case criterion = "Criterion"
    case britbox = "BritBox"
    case acorn = "Acorn TV"
    case shudder = "Shudder"
    case sundance = "Sundance Now"
    case curiosity = "CuriosityStream"
    case dazn = "DAZN"
    case fubo = "FuboTV"
    case sling = "Sling TV"
    case youtube = "YouTube TV"
    case plex = "Plex"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .netflix: return "play.rectangle.fill"
        case .disney: return "star.fill"
        case .prime: return "play.circle.fill"
        case .hbo, .max: return "h.square.fill"
        case .apple: return "applelogo"
        case .paramount: return "mountain.2.fill"
        case .hulu: return "play.tv.fill"
        case .peacock: return "bird.fill"
        case .showtime, .starz, .mgmPlus, .amc: return "tv.fill"
        case .pluto, .tubi: return "play.tv"
        case .crunchyroll: return "play.circle"
        case .discoveryPlus: return "d.circle.fill"
        case .mubi, .criterion: return "film.fill"
        case .britbox, .acorn: return "tv.circle.fill"
        case .shudder, .sundance: return "film"
        case .curiosity: return "lightbulb.fill"
        case .dazn, .fubo, .sling, .youtube: return "sportscourt.fill"
        case .plex: return "play.square.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .netflix: return Color(red: 0.9, green: 0.1, blue: 0.15)
        case .disney: return Color(red: 0.05, green: 0.2, blue: 0.5)
        case .prime: return Color(red: 0.0, green: 0.7, blue: 0.85)
        case .hbo, .max: return Color(red: 0.4, green: 0.1, blue: 0.7)
        case .apple: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .paramount: return Color(red: 0.0, green: 0.4, blue: 0.8)
        case .hulu: return Color(red: 0.1, green: 0.8, blue: 0.4)
        case .peacock: return Color(red: 0.9, green: 0.6, blue: 0.0)
        case .showtime: return Color(red: 0.8, green: 0.0, blue: 0.0)
        case .pluto: return Color(red: 1.0, green: 0.4, blue: 0.0)
        case .tubi: return Color(red: 1.0, green: 0.2, blue: 0.4)
        case .crunchyroll: return Color(red: 1.0, green: 0.6, blue: 0.0)
        case .discoveryPlus: return Color(red: 0.0, green: 0.5, blue: 0.9)
        case .starz: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .mgmPlus: return Color(red: 0.8, green: 0.7, blue: 0.3)
        case .amc: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .mubi: return Color(red: 0.0, green: 0.4, blue: 0.9)
        case .criterion: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .britbox: return Color(red: 0.8, green: 0.1, blue: 0.2)
        case .acorn: return Color(red: 0.9, green: 0.5, blue: 0.1)
        case .shudder: return Color(red: 0.9, green: 0.2, blue: 0.2)
        case .sundance: return Color(red: 0.2, green: 0.5, blue: 0.7)
        case .curiosity: return Color(red: 0.9, green: 0.7, blue: 0.2)
        case .dazn: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .fubo: return Color(red: 0.0, green: 0.7, blue: 0.3)
        case .sling: return Color(red: 0.0, green: 0.4, blue: 0.9)
        case .youtube: return Color(red: 1.0, green: 0.0, blue: 0.0)
        case .plex: return Color(red: 0.9, green: 0.7, blue: 0.1)
        }
    }
}

#Preview {
    PlatformSelector(selectedPlatforms: .constant(Set([.netflix, .disney])))
        .padding()
        .background(Color.theme.background)
}
