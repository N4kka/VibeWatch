import SwiftUI

@MainActor
struct AIRecommendationsView: View {
    @StateObject private var viewModel: AIRecommendationViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @FocusState private var isInputFocused: Bool
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    @State private var showAuthGate = false
    
    private var canUseAI: Bool {
        appState.isAuthenticated
    }
    
    // Dependency-injected initializer (for previews/tests)
    init(viewModel: AIRecommendationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // Default initializer creates the model on the main actor
    init() {
        _viewModel = StateObject(wrappedValue: AIRecommendationViewModel())
    }
    
    private var suggestionChips: [String] {
        // Observe locale changes to re-render localized strings
        _ = localizationManager.localeDidChange
        return [
            "ai.suggestion.chips1".localized,
            "ai.suggestion.chips2".localized,
            "ai.suggestion.chips3".localized,
            "ai.suggestion.chips4".localized
        ]
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header
                Text("ai.title".localized)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.theme.accentOrange, Color.purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.top, 10)
                
                // --- PRO Check & Gating ---
                if canUseAI {
                    // --- AI Chat Content ---
                    chatContent
                } else {
                    authGate
                }
            }
        }
        .onAppear {
            viewModel.updateTokenLimit(isProUser: quotaManager.isProUser)
            presentAccessGate()
            Task { await viewModel.fetchDailyTokenUsage() }
        }
        .onChange(of: appState.isAuthenticated) { _, _ in
            presentAccessGate()
            Task { await viewModel.fetchDailyTokenUsage() }
        }
        .onChange(of: quotaManager.isProUser) { _, _ in
            viewModel.updateTokenLimit(isProUser: quotaManager.isProUser)
            Task { await viewModel.fetchDailyTokenUsage() }
        }
        .sheet(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
        }
    }
    
    private func presentAccessGate() {
        if !appState.isAuthenticated {
            showAuthGate = true
        } else {
            showAuthGate = false
        }
    }
    
    private var authGate: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "sparkles.tv")
                .font(.system(size: 60))
                .foregroundStyle(Color.theme.textSecondary.opacity(0.5))
            
            Text("ai.title".localized)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.theme.textPrimary)
            
            Text("auth.gate.authRequiredAI".localized)
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.theme.textSecondary)
                .padding(.horizontal)
            
            Button {
                presentAccessGate()
            } label: {
                Text("auth.signIn".localized)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.theme.accentOrange)
                    .cornerRadius(16)
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
    }
    
    // MARK: - Chat Content
    
    private var chatContent: some View {
        let inputDisabled = viewModel.isLoading || viewModel.hardLimitReached || !canUseAI
        
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        // Introduction / Empty State
                        if viewModel.messages.isEmpty && !viewModel.isLoading {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkles.tv")
                                    .font(.system(size: 60))
                                    .foregroundStyle(Color.theme.textSecondary.opacity(0.5))
                                
                                Text("ai.describeVibe".localized)
                                    .font(.headline)
                                    .foregroundStyle(Color.theme.textPrimary)
                                
                                Text("ai.subtitle".localized)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.theme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            .padding(.top, 40)
                            
                            // Suggestion Chips
            VStack(alignment: .leading, spacing: 12) {
                Text("ai.tryAsking".localized)
                    .font(.caption)
                    .foregroundStyle(Color.theme.textSecondary)
                    .padding(.leading, 4)
                                
                                FlowLayout(spacing: 10) {
                                    ForEach(suggestionChips, id: \.self) { chip in
                                        Button(action: {
                                            Task {
                                                await viewModel.sendSuggestion(chip)
                                                isInputFocused = false
                                            }
                                        }) {
                                            Text(chip)
                                                .font(.system(size: 14, weight: .medium))
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(Color.theme.cardBackground)
                                                .foregroundStyle(Color.theme.textPrimary)
                                                .clipShape(Capsule())
                                                .overlay(
                                                    Capsule()
                                                        .stroke(Color.theme.separator, lineWidth: 1)
                                                )
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .padding(.bottom, 20) // Add padding to separate intro from chat
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        
                        // Chat Messages
                        LazyVStack(spacing: 16) {
                            ForEach($viewModel.messages) { $message in
                                MessageBubble(
                                    message: $message,
                                    onRegenerate: { newContent in
                                        Task {
                                            await viewModel.regenerateResponse(for: message.id, newContent: newContent)
                                        }
                                    },
                                    onToggleEdit: {
                                        viewModel.toggleEdit(for: message.id)
                                    }
                                )
                                .id(message.id)
                            }
                            
                            // Loading State
                            if viewModel.isLoading {
                                HStack {
                                    ProgressView()
                                        .tint(Color.theme.accentOrange)
                                        .scaleEffect(1.0)
                                    Text("ai.thinking".localized)
                                        .font(.caption)
                                        .foregroundStyle(Color.theme.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 20)
                                .id("loading")
                            }
                            
                            // Error, Soft/Hard Limit Messages
                            if let error = viewModel.error {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                    .padding(.horizontal)
                            } else if viewModel.softLimitReached {
                                Text("ai.softLimitMessage".localized)
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .padding(.horizontal)
                            } else if viewModel.hardLimitReached {
                                Text("ai.hardLimitMessage".localized)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 100) // Spacing for input area
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.messages.count) {
                    if let lastId = viewModel.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.isLoading) { _, newValue in
                    if newValue {
                        withAnimation {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            
            // Input Area
            Divider()
                .background(Color.theme.separator)
            
            // Token Counter
            VStack(spacing: 6) {
                HStack {
                    Text(String(format: "ai.tokensUsage".localized, "\(viewModel.tokensUsedToday)", "\(viewModel.aiTokenLimit)"))
                        .font(.caption2)
                        .foregroundStyle(viewModel.hardLimitReached ? .red : (viewModel.softLimitReached ? .yellow : Color.theme.textSecondary))
                    Spacer()
                    Text("\(max(0, viewModel.tokensRemaining)) \("ai.usage.left".localized)")
                        .font(.caption2)
                        .foregroundStyle(Color.theme.textSecondary)
                }
                
                TokenUsageBar(progress: viewModel.usageProgress, isAtLimit: viewModel.hardLimitReached, isNearLimit: viewModel.softLimitReached)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            HStack(spacing: 12) {
                TextField("ai.placeholder".localized, text: $viewModel.prompt)
                    .focused($isInputFocused)
                    .padding()
                    .background(Color.theme.cardBackground)
                    .cornerRadius(25)
                    .foregroundStyle(Color.theme.textPrimary)
                    .submitLabel(.send)
                    .disabled(inputDisabled)
                    .onSubmit {
                        Task {
                            await viewModel.sendMessage()
                        }
                    }
                
                Button(action: {
                    Task {
                        await viewModel.sendMessage()
                        isInputFocused = false
                    }
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            viewModel.prompt.isEmpty || viewModel.hardLimitReached ? Color.theme.textSecondary : Color.theme.accentOrange
                        )
                }
                .disabled(viewModel.prompt.isEmpty || inputDisabled)
            }
            .padding()
            .background(Color.theme.background.opacity(0.95))
        }
    }
}

private struct TokenUsageBar: View {
    let progress: Double
    let isAtLimit: Bool
    let isNearLimit: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.theme.cardBackground)
                
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: isAtLimit ? [.red] : (isNearLimit ? [.yellow, .orange] : [Color.theme.accentOrange, .purple]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, geometry.size.width * min(1, progress)))
            }
        }
        .frame(height: 12)
        .animation(.easeInOut(duration: 0.2), value: progress)
    }
}

struct MessageBubble: View {
    @Binding var message: AIMessage
    let onRegenerate: (String) -> Void
    let onToggleEdit: () -> Void
    
    @State private var editedContent: String = ""
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                
                if message.isEditing {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("ai.editMessage".localized, text: $editedContent)
                            .padding(10)
                            .background(Color.theme.cardBackground)
                            .cornerRadius(12)
                            .foregroundStyle(Color.theme.textPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.theme.accentOrange, lineWidth: 1)
                            )
                        
                        HStack {
                            Button("common.cancel".localized) {
                                onToggleEdit()
                            }
                            .font(.caption)
                            .foregroundStyle(Color.theme.textSecondary)
                            
                            Button("ai.saveRegenerate".localized) {
                                onRegenerate(editedContent)
                            }
                            .font(.caption.bold())
                            .foregroundStyle(Color.theme.accentOrange)
                        }
                    }
                    .frame(maxWidth: 300)
                    .onAppear {
                        editedContent = message.content
                    }
                } else {
                    Text(message.content)
                        .padding(12)
                        .background(
                            LinearGradient(
                                colors: [Color.theme.accentOrange, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .foregroundStyle(.white)
                        .cornerRadius(16, corners: [.topLeft, .topRight, .bottomLeft])
                        .onLongPressGesture {
                            onToggleEdit()
                        }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.content)
                        .padding(16)
                        .background(Color.theme.cardBackground)
                        .foregroundStyle(Color.theme.textPrimary)
                        .cornerRadius(16, corners: [.topLeft, .topRight, .bottomRight])
                        .lineSpacing(4)
                }
                Spacer()
            }
        }
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// Helper for suggestion chips layout
struct FlowLayout: Layout {
            var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = flow(proposal: proposal, subviews: subviews, perform: false)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = flow(proposal: proposal, subviews: subviews, perform: true, in: bounds)
    }

    private func flow(proposal: ProposedViewSize, subviews: Subviews, perform: Bool, in bounds: CGRect = .zero) -> (size: CGSize, maxX: CGFloat) {
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        
        let containerWidth = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > containerWidth {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            if perform {
                subview.place(at: CGPoint(x: bounds.minX + currentX, y: bounds.minY + currentY), proposal: .unspecified)
            }

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), maxWidth)
    }
}

