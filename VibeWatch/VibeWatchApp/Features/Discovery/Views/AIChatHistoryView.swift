import SwiftUI

/// Sheet "Le tue chat": cronologia delle sessioni Vibe AI raggruppate per data, con nuova chat.
struct AIChatHistoryView: View {
    @ObservedObject var viewModel: AIRecommendationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionPendingDeletion: AIChatSessionSummary?
    @State private var sessionPendingRename: AIChatSessionSummary?
    @State private var renameDraft: String = ""

    private struct SessionGroup: Identifiable {
        let titleKey: String
        let sessions: [AIChatSessionSummary]
        var id: String { titleKey }
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ai.history.title".localized)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.theme.textPrimary)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.theme.textPrimary)
                            .frame(width: 38, height: 38)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)

                Button {
                    Task {
                        await viewModel.startNewChat()
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                        Text("ai.newChat".localized)
                            .font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.theme.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 18)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedSessions) { group in
                            Text(group.titleKey.localized)
                                .font(.system(size: 13, weight: .bold))
                                .kerning(1.5)
                                .foregroundStyle(Color.theme.textSecondary)
                                .padding(.top, 14)
                                .padding(.leading, 4)

                            ForEach(group.sessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .padding(.top, 6)
            }
        }
        .task {
            AnalyticsService.shared.logScreenView(screenName: "AIChatHistory")
            await viewModel.loadSessions()
        }
        .confirmationDialog(
            "ai.history.deleteConfirmTitle".localized,
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("ai.history.delete".localized, role: .destructive) {
                if let session = sessionPendingDeletion {
                    Task { await viewModel.deleteSession(session.sessionId) }
                }
                sessionPendingDeletion = nil
            }
            Button("common.cancel".localized, role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            Text(sessionPendingDeletion?.title ?? "")
        }
        .alert(
            "ai.history.rename".localized,
            isPresented: Binding(
                get: { sessionPendingRename != nil },
                set: { if !$0 { sessionPendingRename = nil } }
            )
        ) {
            TextField("ai.history.renamePlaceholder".localized, text: $renameDraft)
            Button("common.save".localized) {
                if let session = sessionPendingRename {
                    Task { await viewModel.renameSession(session.sessionId, title: renameDraft) }
                }
                sessionPendingRename = nil
            }
            Button("common.cancel".localized, role: .cancel) {
                sessionPendingRename = nil
            }
        }
    }

    private func sessionRow(_ session: AIChatSessionSummary) -> some View {
        let isCurrent = session.sessionId == ConversationMemoryManager.shared.sessionId

        return Button {
            Task {
                await viewModel.selectSession(session.sessionId)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 15))
                    .foregroundStyle(isCurrent ? Color.theme.accentOrange : Color.theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(
                        (isCurrent ? Color.theme.accentOrange.opacity(0.16) : Color.white.opacity(0.06))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color.theme.accentOrange : Color.theme.textPrimary)
                        .lineLimit(1)

                    if let meta = metaLine(for: session) {
                        Text(meta)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.theme.accentOrange.opacity(0.8))
                        .rotationEffect(.degrees(45))
                }

                Text(relativeTime(for: session.lastMessageAt))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.theme.textSecondary)
            }
            .padding(12)
            .background(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isCurrent ? Color.theme.accentOrange.opacity(0.55) : .clear, lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // Long press: fissa in alto, rinomina, elimina (con conferma).
        .contextMenu {
            Button {
                Task { await viewModel.togglePin(session.sessionId) }
            } label: {
                Label(
                    session.isPinned ? "ai.history.unpin".localized : "ai.history.pin".localized,
                    systemImage: session.isPinned ? "pin.slash" : "pin"
                )
            }

            Button {
                renameDraft = session.title
                sessionPendingRename = session
            } label: {
                Label("ai.history.rename".localized, systemImage: "pencil")
            }

            Button(role: .destructive) {
                sessionPendingDeletion = session
            } label: {
                Label("ai.history.delete".localized, systemImage: "trash")
            }
        }
    }

    private func metaLine(for session: AIChatSessionSummary) -> String? {
        guard !session.proposedMediaIds.isEmpty else { return nil }
        var parts = [String(format: "ai.history.proposed".localized, session.proposedMediaIds.count)]
        let inWatchlist = viewModel.watchlistCount(for: session)
        if inWatchlist > 0 {
            parts.append(String(format: "ai.history.inWatchlist".localized, inWatchlist))
        }
        return parts.joined(separator: " · ")
    }

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        var pinned: [AIChatSessionSummary] = []
        var today: [AIChatSessionSummary] = []
        var lastWeek: [AIChatSessionSummary] = []
        var earlier: [AIChatSessionSummary] = []

        for session in viewModel.sessions {
            if session.isPinned {
                pinned.append(session)
            } else if calendar.isDateInToday(session.lastMessageAt) {
                today.append(session)
            } else if let days = calendar.dateComponents([.day], from: session.lastMessageAt, to: now).day,
                      days < 7 {
                lastWeek.append(session)
            } else {
                earlier.append(session)
            }
        }

        var groups: [SessionGroup] = []
        if !pinned.isEmpty { groups.append(SessionGroup(titleKey: "ai.history.pinnedSection", sessions: pinned)) }
        if !today.isEmpty { groups.append(SessionGroup(titleKey: "ai.history.today", sessions: today)) }
        if !lastWeek.isEmpty { groups.append(SessionGroup(titleKey: "ai.history.last7days", sessions: lastWeek)) }
        if !earlier.isEmpty { groups.append(SessionGroup(titleKey: "ai.history.earlier", sessions: earlier)) }
        return groups
    }
}
