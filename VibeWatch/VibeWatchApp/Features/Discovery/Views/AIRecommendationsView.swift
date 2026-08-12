import SwiftUI

@MainActor
struct AIRecommendationsView: View {
    @StateObject private var viewModel: AIRecommendationViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool
    @ObservedObject private var localizationManager = LocalizationManager.shared

    @State private var showAuthGate = false
    @State private var showAIPaywall = false
    @State private var showHistorySheet = false
    @State private var detailCard: AIRecommendationCardModel?

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

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                AIChatHeader(
                    requestsUsedToday: viewModel.requestsUsedToday,
                    dailyRequestLimit: viewModel.dailyRequestLimit,
                    chatTitle: viewModel.chatTitle,
                    onClose: { dismiss() },
                    onNewChat: { Task { await viewModel.startNewChat() } },
                    onShowHistory: { showHistorySheet = true }
                )

                Divider().background(Color.theme.separator)

                if canUseAI {
                    chatContent
                } else {
                    authGate
                }
            }
        }
        .onAppear {
            viewModel.updateRequestLimit(isProUser: quotaManager.isProUser)
            presentAccessGate()
            Task { await viewModel.fetchDailyRequestUsage() }
            evaluateAIPaywallPresentation()
        }
        .onChange(of: appState.isAuthenticated) { _, _ in
            presentAccessGate()
            Task { await viewModel.fetchDailyRequestUsage() }
            evaluateAIPaywallPresentation()
        }
        .onChange(of: quotaManager.isProUser) { _, _ in
            viewModel.updateRequestLimit(isProUser: quotaManager.isProUser)
            Task { await viewModel.fetchDailyRequestUsage() }
            evaluateAIPaywallPresentation()
        }
        .onChange(of: viewModel.requestsUsedToday) { _, _ in
            evaluateAIPaywallPresentation()
        }
        .onChange(of: viewModel.dailyRequestLimit) { _, _ in
            evaluateAIPaywallPresentation()
        }
        .sheet(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
        }
        .fullScreenCover(isPresented: $showAIPaywall) {
            DailyLimitPaywallView(
                isPresented: $showAIPaywall,
                paywallType: .aiQuota,
                source: "ai_quota"
            )
        }
        .sheet(isPresented: $showHistorySheet) {
            AIChatHistoryView(viewModel: viewModel)
        }
        .sheet(item: $detailCard) { card in
            NavigationStack {
                Group {
                    if card.mediaType == .tv {
                        TVShowDetailView(tvShowId: card.tmdbId)
                    } else {
                        MovieDetailView(movieId: card.tmdbId)
                    }
                }
            }
        }
    }

    private func presentAccessGate() {
        if !appState.isAuthenticated {
            showAuthGate = true
        } else {
            showAuthGate = false
        }
    }

    private func evaluateAIPaywallPresentation() {
        guard appState.isAuthenticated else { return }
        guard !quotaManager.isProUser else {
            showAIPaywall = false
            return
        }

        if viewModel.hardLimitReached && !showAIPaywall {
            showAIPaywall = true
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
                        if viewModel.messages.isEmpty && !viewModel.isLoading {
                            AIEmptyStateView { starter in
                                Task {
                                    await viewModel.sendSuggestion(starter)
                                    isInputFocused = false
                                }
                            }
                        }

                        LazyVStack(spacing: 28) {
                            ForEach($viewModel.messages) { $message in
                                AIChatMessageView(
                                    message: $message,
                                    isLastAssistantMessage: message.id == lastAssistantMessageId,
                                    isInWatchlist: { viewModel.isCardInWatchlist($0) },
                                    onAddCard: { card in Task { await viewModel.addCardToWatchlist(card) } },
                                    onCardDetails: { detailCard = $0 },
                                    onThumb: { positive in viewModel.recordFeedback(for: message.id, positive: positive) },
                                    onMore: { Task { await viewModel.requestMore() } },
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

                            if viewModel.isLoading {
                                AILoadingStateView()
                                    .id("loading")
                            }

                            if let error = viewModel.error {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                    .padding(.horizontal)
                            } else if viewModel.hardLimitReached {
                                Text("ai.hardLimitMessage".localized)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
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

            AIFilterChipsRow(
                availableFilters: viewModel.availableFilters,
                activeFilters: viewModel.activeFilters,
                onToggle: { viewModel.toggleFilter($0) }
            )
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()
                .background(Color.theme.separator)

            AIChatInputBar(
                prompt: $viewModel.prompt,
                isDisabled: inputDisabled,
                onSend: {
                    Task {
                        await viewModel.sendMessage()
                        isInputFocused = false
                    }
                },
                focus: $isInputFocused
            )
        }
    }

    private var lastAssistantMessageId: UUID? {
        viewModel.messages.last(where: { !$0.isUser })?.id
    }
}

/// Un messaggio della chat: bolla utente (editabile) oppure risposta AI con testo + card.
private struct AIChatMessageView: View {
    @Binding var message: AIMessage
    let isLastAssistantMessage: Bool
    let isInWatchlist: (AIRecommendationCardModel) -> Bool
    let onAddCard: (AIRecommendationCardModel) -> Void
    let onCardDetails: (AIRecommendationCardModel) -> Void
    let onThumb: (Bool) -> Void
    let onMore: () -> Void
    let onRegenerate: (String) -> Void
    let onToggleEdit: () -> Void

    @State private var editedContent: String = ""

    var body: some View {
        if message.isUser {
            userBubble
        } else {
            assistantContent
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)

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
                    .font(.system(size: 16))
                    .foregroundStyle(Color.theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.theme.accentOrange.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.theme.accentOrange.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onLongPressGesture {
                        onToggleEdit()
                    }
            }
        }
    }

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !message.text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.theme.accentOrange, Color(hex: "e858c8")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 24, height: 24)
                        .padding(.top, 2)

                    Text(message.text)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.theme.textPrimary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }

            ForEach(message.cards) { card in
                AIRecommendationCardView(
                    card: card,
                    isInWatchlist: isInWatchlist(card),
                    onAdd: { onAddCard(card) },
                    onDetails: { onCardDetails(card) }
                )
            }

            if !message.cards.isEmpty && isLastAssistantMessage {
                AIFeedbackRow(
                    feedback: message.feedback,
                    onThumbUp: { onThumb(true) },
                    onThumbDown: { onThumb(false) },
                    onMore: onMore
                )
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
