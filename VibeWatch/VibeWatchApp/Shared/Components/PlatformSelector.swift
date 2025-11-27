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
