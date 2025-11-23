import SwiftUI

extension View {
    /// Adds a swipe-back gesture that only activates from the left half of the screen
    /// to dismiss the current view without interfering with ScrollViews.
    func swipeBackGesture(onSwipeBack: @escaping () -> Void) -> some View {
        self.modifier(SwipeBackGestureModifier(onSwipeBack: onSwipeBack))
    }
}

struct SwipeBackGestureModifier: ViewModifier {
    let onSwipeBack: () -> Void
    
    @State private var isTrackingEdgeSwipe = false
    
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        // Only start tracking if:
                        // 1. Started from left 50% of screen
                        // 2. Horizontal movement is significantly more than vertical
                        if !isTrackingEdgeSwipe {
                            let screenWidth = UIScreen.main.bounds.width
                            let startX = value.startLocation.x
                            let horizontal = value.translation.width
                            let vertical = abs(value.translation.height)
                            
                            if startX < screenWidth * 0.5 && horizontal > 0 && horizontal > vertical * 2 {
                                isTrackingEdgeSwipe = true
                            }
                        }
                    }
                    .onEnded { value in
                        defer {
                            isTrackingEdgeSwipe = false
                        }
                        
                        guard isTrackingEdgeSwipe else { return }
                        
                        let horizontalMovement = value.translation.width
                        let verticalMovement = abs(value.translation.height)
                        
                        // Swipe right with sufficient distance and mostly horizontal
                        if horizontalMovement > 100 && verticalMovement < 50 {
                            onSwipeBack()
                        }
                    }
            )
    }
}
