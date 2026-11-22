//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Dev", icon: "terminal.fill", view: .dev),
    TabModel(label: "System", icon: "gauge.with.dots.needle.33percent", view: .system)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var devActivity = DevActivityStore.shared
    @Default(.boringShelf) private var boringShelf
    @Default(.enableSystemTab) private var enableSystemTab
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home: true
            case .shelf: boringShelf
            case .dev: !devActivity.items.isEmpty
            case .system: enableSystemTab
            }
        }
    }

    var body: some View {
        let shown = visibleTabs
        let buttonPadding: CGFloat = shown.count >= 4 ? 11 : 15

        HStack(spacing: 0) {
            ForEach(shown) { tab in
                    TabButton(
                        label: tab.label,
                        icon: tab.icon,
                        selected: coordinator.currentView == tab.view,
                        horizontalPadding: buttonPadding
                    ) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
