import SwiftUI

/// Subscribing to "tell me when this lands somewhere", in one place.
///
/// There were three copies of this gesture in the app and only one of them worked properly. The
/// media-detail button had the full state machine; the one in Lists showed the confirmation alert
/// *before* writing, swallowed failures with `try?`, never changed appearance and could be tapped
/// as many times as you liked; the one under an actor's filmography promised a notification and
/// wrote nothing at all.
///
/// This is that state machine, extracted: the alert appears only after the write succeeds, the
/// button is disabled while in flight and stays disabled once enrolled, a failure says so through
/// the toast instead of quietly reverting, and the enrolled state survives relaunch through the
/// same `AppStorage` set the detail screen already used.
enum MediaNotificationEnroller {
    /// Adds the title to the watchlist if it is not saved yet, then subscribes to its alerts.
    /// Returns the new enrollment blob to write back into `AppStorage`.
    @MainActor
    static func enroll(
        movie: Movie,
        mediaType: MediaType,
        enrollmentData: Data,
        userId: String?
    ) async throws -> Data {
        let listManager = ListManager.shared
        if !listManager.isInList(listId: listManager.watchlist.id, mediaId: movie.id, mediaType: mediaType) {
            try? await listManager.addToList(listId: listManager.watchlist.id, movie: movie, mediaType: mediaType)
        }

        try await LiveNotificationRepository.shared.toggleAlert(
            mediaId: movie.id,
            mediaType: mediaType,
            enabled: true
        )

        var enrolled = MediaNotificationEnrollmentCodec.decode(enrollmentData)
        enrolled.insert(MediaNotificationEnrollmentCodec.key(
            userId: userId,
            mediaId: movie.id,
            mediaType: mediaType
        ))
        return try MediaNotificationEnrollmentCodec.encode(enrolled)
    }
}

/// How a `NotifyMeButton` paints itself. The gesture is shared; the surroundings are not.
enum NotifyMeButtonStyle {
    /// Discreet capsule on a card row (Lists).
    case subtle
    /// Filled accent button that fills its container (actor filmography).
    case prominent
}

struct NotifyMeButton: View {
    let movie: Movie
    let mediaType: MediaType
    let title: String
    var style: NotifyMeButtonStyle = .subtle

    @ObservedObject private var authService = AuthService.shared
    @AppStorage("enabledMediaAvailabilityAlerts") private var enrollmentData = Data()
    @State private var state: MediaNotificationCTAState = .idle
    @State private var showConfirmation = false

    var body: some View {
        Button(action: enroll) {
            label
        }
        .buttonStyle(.plain)
        .disabled(state.isButtonDisabled)
        .alert("lists.notifyMeTitle".localized, isPresented: $showConfirmation) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text(String(format: "lists.notifyMeMessage".localized, title))
        }
        .task(id: enrollmentKey) { restoreState() }
        .onChange(of: enrollmentData) { _, _ in restoreState() }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .subtle:
            HStack(spacing: 5) {
                icon.font(.system(size: 12, weight: .semibold))
                Text(state.titleKey.localized)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))

        case .prominent:
            HStack(spacing: 5) {
                Text(state.titleKey.localized)
                    .font(.system(size: 12, weight: .bold))
                icon.font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(state == .enabled ? Color.white.opacity(0.12) : Color.theme.accentOrange)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:     Image(systemName: "bell")
        case .enabling: ProgressView().controlSize(.mini)
        case .enabled:  Image(systemName: "checkmark")
        }
    }

    private var enrollmentKey: String {
        MediaNotificationEnrollmentCodec.key(
            userId: authService.currentUser?.id,
            mediaId: movie.id,
            mediaType: mediaType
        )
    }

    private func enroll() {
        guard state == .idle else { return }
        state = .enabling
        Task {
            do {
                enrollmentData = try await MediaNotificationEnroller.enroll(
                    movie: movie,
                    mediaType: mediaType,
                    enrollmentData: enrollmentData,
                    userId: authService.currentUser?.id
                )
                state = .enabled
                // Only now: the confirmation used to be shown before the write, so a failed
                // request still told the user we would notify them.
                showConfirmation = true
            } catch {
                state = .idle
                ToastCenter.shared.show(error: "mediaDetail.notifyMeFailed".localized)
            }
        }
    }

    private func restoreState() {
        let enrolled = MediaNotificationEnrollmentCodec.decode(enrollmentData)
        state = enrolled.contains(enrollmentKey) ? .enabled : .idle
    }
}
