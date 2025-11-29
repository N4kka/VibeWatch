import SwiftUI

struct AIRecommendationsView: View {
    @StateObject private var viewModel = AIRecommendationViewModel()
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        ZStack {
            // Background
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header
                Text("Vibe AI")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.theme.accentOrange, Color.purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.top, 10)
                
                // Content Area
                ScrollView {
                    VStack(spacing: 24) {
                        // Introduction / Empty State
                        if viewModel.responseText.isEmpty && !viewModel.isLoading {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkles.tv")
                                    .font(.system(size: 60))
                                    .foregroundStyle(Color.theme.textSecondary.opacity(0.5))
                                
                                Text("Describe your vibe")
                                    .font(.headline)
                                    .foregroundStyle(Color.theme.textPrimary)
                                
                                Text("Tell me what you're in the mood for, and I'll find the perfect watch.")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.theme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            .padding(.top, 40)
                            
                            // Suggestion Chips
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Try asking for...")
                                    .font(.caption)
                                    .foregroundStyle(Color.theme.textSecondary)
                                    .padding(.leading, 4)
                                
                                FlowLayout(spacing: 10) {
                                    ForEach(viewModel.suggestionChips, id: \.self) { chip in
                                        Button(action: {
                                            viewModel.applySuggestion(chip)
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
                            }
                            .padding(.horizontal)
                        }
                        
                        // Loading State
                        if viewModel.isLoading {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .tint(Color.theme.accentOrange)
                                    .scaleEffect(1.5)
                                
                                Text("Finding the best matches...")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        }
                        
                        // Response
                        if !viewModel.responseText.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Here's what I found:")
                                    .font(.headline)
                                    .foregroundStyle(Color.theme.textSecondary)
                                
                                Text(viewModel.responseText)
                                    .font(.body)
                                    .lineSpacing(6)
                                    .foregroundStyle(Color.theme.textPrimary)
                                    .padding()
                                    .background(Color.theme.cardBackground)
                                    .cornerRadius(16)
                            }
                            .padding(.horizontal)
                        }
                        
                        // Error
                        if let error = viewModel.error {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding()
                        }
                    }
                    .padding(.bottom, 100) // Spacing for input area
                }
                .scrollDismissesKeyboard(.interactively)
                
                Spacer()
                
                // Input Area
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.theme.separator)
                    
                    HStack(spacing: 12) {
                        TextField("E.g. 'Sci-fi with a plot twist'", text: $viewModel.prompt)
                            .focused($isInputFocused)
                            .padding()
                            .background(Color.theme.cardBackground)
                            .cornerRadius(25)
                            .foregroundStyle(Color.theme.textPrimary)
                            .submitLabel(.send)
                            .onSubmit {
                                Task {
                                    await viewModel.getRecommendations()
                                }
                            }
                        
                        Button(action: {
                            Task {
                                await viewModel.getRecommendations()
                                isInputFocused = false
                            }
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(
                                    viewModel.prompt.isEmpty ? Color.theme.textSecondary : Color.theme.accentOrange
                                )
                        }
                        .disabled(viewModel.prompt.isEmpty || viewModel.isLoading)
                    }
                    .padding()
                    .background(Color.theme.background.opacity(0.95))
                }
            }
        }
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
        flow(proposal: proposal, subviews: subviews, perform: true, in: bounds)
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
