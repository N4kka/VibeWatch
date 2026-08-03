import SwiftUI

struct ClipsSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ClipsSearchViewModel()
    @FocusState private var isSearchFocused: Bool
    private let initialQuery: String?
    
    init(initialQuery: String? = nil) {
        self.initialQuery = initialQuery
    }
    
    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            
            content
                .ignoresSafeArea(.all, edges: .bottom)
            
            searchBar
        }
        .navigationBarHidden(true)
        .swipeBackGesture {
            dismiss()
        }
        .onAppear {
            if let initialQuery, !initialQuery.isEmpty {
                viewModel.query = initialQuery
                viewModel.updateQuery(initialQuery)
                Task { await viewModel.performSearch() }
            }
            isSearchFocused = true
            Task {
                await viewModel.loadShowcaseClips()
            }
        }
    }
    
    private var content: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error {
                errorView(error)
            } else if viewModel.clips.isEmpty {
                emptyStateView
            } else {
                clipsScrollView
            }
        }
    }
    
    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.7))
                    
                    TextField("clips.search.placeholder".localized, text: $viewModel.query)
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.none)
                        .focused($isSearchFocused)
                        .onSubmit {
                            Task { await viewModel.performSearch() }
                        }
                        .onChange(of: viewModel.query) { _, newValue in
                            viewModel.updateQuery(newValue)
                        }
                    
                    if !viewModel.query.isEmpty {
                        Button {
                            viewModel.query = ""
                            viewModel.reset()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                
                Button {
                    Task { await viewModel.performSearch() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 42, height: 42)
                        .background(Color.theme.accentOrange)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, safeAreaTop + 8)
            .padding(.bottom, 12)
        }
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.9),
                    Color.black.opacity(0.6),
                    Color.black.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }
    
    private var clipsScrollView: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.clips.enumerated()), id: \.offset) { index, clip in
                            ZStack(alignment: .topLeading) {
                                ClipPlayerView(
                                    clip: clip,
                                    isCurrentClip: viewModel.currentIndex == index,
                                    onBecomeVisible: {
                                        viewModel.currentIndex = index
                                    },
                                    onLikeToggle: { isLiked in
                                        viewModel.toggleLike(for: clip.id, isLiked: isLiked)
                                    }
                                )
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .id(index)
                                
                                clipBadge(for: index)
                                    .padding(.top, safeAreaTop + 12)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                // Stesso nome usato da ClipPlayerView per misurare la visibilità della pagina.
                .coordinateSpace(name: "clipsScroll")
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: .init(get: {
                    viewModel.currentIndex
                }, set: { newValue in
                    if let newIndex = newValue {
                        viewModel.currentIndex = newIndex
                    }
                }))
                .onChange(of: viewModel.clips.count) { _, _ in
                    guard !viewModel.clips.isEmpty else { return }
                    proxy.scrollTo(0, anchor: .top)
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.8))
            
            Text(viewModel.hasSearched ? "clips.search.emptyTitle".localized : "clips.search.showcaseTitle".localized)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            
            Text(viewModel.hasSearched ? "clips.search.emptySubtitle".localized : "clips.search.showcaseSubtitle".localized)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(_ error: AppError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.orange)
            
            Text(error.errorDescription ?? "Oops")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            
            Button {
                Task { await viewModel.performSearch() }
            } label: {
                Text("common.tryAgain".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 200, height: 48)
                    .background(Color.theme.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func clipBadge(for index: Int) -> some View {
        let isMatch = index < viewModel.matches.count
        let label = isMatch ? "clips.search.matched" : "clips.search.recommended"
        
        return Text(label.localized)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isMatch ? Color.theme.accentOrange : Color.white.opacity(0.14))
            .clipShape(Capsule())
            .foregroundColor(isMatch ? .black : .white)
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4)
    }
}
