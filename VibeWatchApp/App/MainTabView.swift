import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                DiscoveryView()
                    .tag(0)
                
                ClipsView()
                    .tag(1)
                
                ListsView()
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            LiquidGlassBottomBar(selectedTab: $selectedTab)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .background(Color.theme.background.ignoresSafeArea())
    }
}

struct LiquidGlassBottomBar: View {
    @Binding var selectedTab: Int
    
    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(
                icon: "house.fill",
                title: "Discovery",
                isSelected: selectedTab == 0
            ) {
                selectedTab = 0
            }
            
            TabBarButton(
                icon: "play.rectangle.fill",
                title: "Clips",
                isSelected: selectedTab == 1
            ) {
                selectedTab = 1
            }
            
            TabBarButton(
                icon: "list.bullet",
                title: "Lists",
                isSelected: selectedTab == 2
            ) {
                selectedTab = 2
            }
        }
        .frame(height: 60)
        .liquidGlass()
        .clipShape(RoundedRectangle(cornerRadius: 30))
    }
}

struct TabBarButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? .theme.accentOrange : .theme.textSecondary)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
