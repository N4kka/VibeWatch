import SwiftUI
import AVKit

struct ClipsView: View {
    @StateObject private var viewModel = ClipsViewModel()
    @State private var currentIndex = 0
    
    var body: some View {
        ZStack {
            if viewModel.clips.isEmpty {
                emptyStateView
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(Array(viewModel.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipPlayerView(clip: clip)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await viewModel.loadClips()
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundColor(.theme.textSecondary)
            
            Text("No Clips Available")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("Check back later for exciting scenes from your favorite movies and shows")
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

struct ClipPlayerView: View {
    let clip: Clip
    @State private var player: AVPlayer?
    @State private var isLiked = false
    @State private var showComments = false
    @State private var showAddToList = false
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }
            
            VStack(alignment: .trailing, spacing: 20) {
                ClipActionButton(
                    icon: isLiked ? "heart.fill" : "heart",
                    count: clip.likes,
                    color: isLiked ? .red : .white
                ) {
                    isLiked.toggle()
                }
                
                ClipActionButton(
                    icon: "message",
                    count: clip.comments,
                    color: .white
                ) {
                    showComments = true
                }
                
                ClipActionButton(
                    icon: "plus",
                    text: "Add to List",
                    color: .white
                ) {
                    showAddToList = true
                }
                
                ClipActionButton(
                    icon: "square.and.arrow.up",
                    color: .white
                ) {
                    shareClip()
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 100)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(clip.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                
                Text(clip.description)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
            .padding(.trailing, 80)
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .sheet(isPresented: $showComments) {
            CommentsView(clipId: clip.id)
        }
        .sheet(isPresented: $showAddToList) {
            AddToListView()
        }
    }
    
    private func setupPlayer() {
        guard let url = URL(string: clip.videoURL) else { return }
        player = AVPlayer(url: url)
        player?.play()
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }
    
    private func shareClip() {
        // TODO: Implement share functionality
    }
}

struct ClipActionButton: View {
    let icon: String
    var count: Int?
    var text: String?
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 44, height: 44)
                
                if let count = count {
                    Text(formatCount(count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                } else if let text = text {
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
    }
    
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

struct CommentsView: View {
    let clipId: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Text("Comments")
                    .font(.system(size: 20, weight: .bold))
                    .padding()
                
                Spacer()
                
                Text("No comments yet")
                    .foregroundColor(.theme.textSecondary)
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AddToListView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Add to List")
                    .font(.system(size: 20, weight: .bold))
                    .padding()
                
                Button {
                    // TODO: Create new list
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Create New List")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
