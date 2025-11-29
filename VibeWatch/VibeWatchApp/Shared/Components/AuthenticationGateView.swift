import SwiftUI

struct AuthenticationGateView: View {
    @Binding var isPresented: Bool
    @State private var activeAuthSheet: AuthSheet?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { outerGeometry in
            ZStack {
                // Background overlay with opacity based on drag
                Color.black.opacity(max(0, 0.45 * (1.0 - Double(dragOffset) / 400.0)))
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false // Allows tapping background to dismiss
                    }
                
                VStack {
                    VStack(spacing: 24) { // This is the actual panel content
                        // Drag indicator
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 46, height: 5)
                            .padding(.top, 14)

                        VStack(spacing: 16) { // hero section
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [Color.orange, Color.pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 88, height: 88)
                                    .shadow(color: Color.orange.opacity(0.4), radius: 20, x: 0, y: 10)

                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            VStack(spacing: 8) {
                                Text("Create an Account")
                                    .font(.system(size: 24, weight: .bold))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.primary)

                                Text("You need an account to create custom lists and sync them across your devices.")
                                    .font(.system(size: 15))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(spacing: 12) { // action buttons
                            Button {
                                activeAuthSheet = .signUp
                            } label: {
                                Text("Create free account")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.orange, Color.orange.opacity(0.85)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(16)
                                    .shadow(color: Color.orange.opacity(0.3), radius: 10, x: 0, y: 5)
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
                        
                        Button {
                            isPresented = false
                        } label: {
                            Text("Skip for now")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(14)
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(UIColor.systemBackground))
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
                                        isPresented = false
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .frame(height: outerGeometry.size.height * 0.6) // 60% screen height
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
            .sheet(item: $activeAuthSheet) { sheet in
                switch sheet {
                case .signUp:
                    SignUpView()
                case .signIn:
                    SignInView()
                }
            }
        }
    }
    
    private enum AuthSheet: Identifiable {
        case signUp
        case signIn
        var id: Int { self == .signUp ? 0 : 1 }
    }
}
