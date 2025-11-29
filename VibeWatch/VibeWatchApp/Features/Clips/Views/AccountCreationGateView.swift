import SwiftUI

/// Gate displayed after anonymous users exhaust their daily clip allowance.
struct AccountCreationGateView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @Binding var isPresented: Bool
    var onComeBack: (() -> Void)?
    var onAccountCreated: (() -> Void)?

    @State private var activeAuthSheet: AuthSheet?
    @State private var countdownText = ""
    @State private var dragOffset: CGFloat = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { outerGeometry in
            ZStack {
                Color.black.opacity(max(0, 0.45 * (1.0 - Double(dragOffset) / 400.0)))
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissGate()
                    }

                VStack { // This is the outermost VStack, taking full height, pushing content to bottom
                    VStack(spacing: 24) { // This is the actual panel content
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 46, height: 5)
                            .padding(.top, 14)

                        heroSection

                        benefitsList

                        actionButtons

                        countdownView

                        Button {
                            dismissGate()
                            onComeBack?()
                        } label: {
                            Text("Come back tomorrow")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.gray.opacity(0.15))
                                .cornerRadius(14)
                        }

                        Text("Signing up is free and takes less than a minute.")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(red: 28/255, green: 28/255, blue: 30/255))
                            .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: -8)
                    )
                    .offset(y: max(0, dragOffset))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.height > 0 {
                                    dragOffset = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if value.translation.height > 150 {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        dismissGate()
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .frame(height: outerGeometry.size.height / 2)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
            .onAppear {
                countdownText = quotaManager.timeUntilResetFormatted()
            }
            .sheet(item: $activeAuthSheet) { sheet in
                switch sheet {
                case .signUp:
                    SignUpView()
                        .environmentObject(appState)
                case .signIn:
                    SignInView()
                        .environmentObject(appState)
                }
            }
            .onReceive(timer) { _ in
                countdownText = quotaManager.timeUntilResetFormatted()
            }
            .onChange(of: appState.isAuthenticated) { _, isAuthenticated in
                guard isAuthenticated else { return }
                dismissGate()
                onAccountCreated?()
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.orange, Color.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.orange.opacity(0.4), radius: 20, x: 0, y: 10)

                Image(systemName: "sparkles.tv")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("Create your free VibeWatch account")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)

            Text("You’ve enjoyed today’s 15 free clips. Sign up to sync your progress and unlock tomorrow’s drops instantly.")
                .font(.system(size: 15))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            BenefitRow(text: "Save your favorite clips")
            BenefitRow(text: "Sync across all your devices")
            BenefitRow(text: "Get personalized recommendations")
        }
        .padding(.top, 8)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                activeAuthSheet = .signUp
            } label: {
                Text("Create free account")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 1, green: 0.6, blue: 0.3), Color.orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(28)
            }

            Button {
                activeAuthSheet = .signIn
            } label: {
                Text("I already have an account")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(14)
            }
        }
    }

    private var countdownView: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.system(size: 14))
                .foregroundColor(.gray)

            Text("Reset in \(countdownText)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)

            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func dismissGate() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            isPresented = false
        }
    }

    private enum AuthSheet: Identifiable {
        case signUp
        case signIn
        var id: Int { self == .signUp ? 0 : 1 }
    }

    private struct BenefitRow: View {
        let text: String

        var body: some View {
            HStack(spacing: 12) {
                // Orange checkmark circle matching paywall style
                ZStack {
                    Circle()
                        .fill(Color(red: 1, green: 0.55, blue: 0.2))
                        .frame(width: 22, height: 22)

                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                }

                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(.white)

                Spacer()
            }
        }
    }
}
