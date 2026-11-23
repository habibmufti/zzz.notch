//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject var devActivity = DevActivityStore.shared
    @ObservedObject var notificationManager = SystemNotificationManager.shared
    @Default(.boringShelf) private var boringShelf
    @Default(.enableSystemTab) private var enableSystemTab
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if ((!shelfState.isEmpty || coordinator.alwaysShowTabs) && boringShelf)
                    || !devActivity.items.isEmpty
                    || (coordinator.alwaysShowTabs && enableSystemTab) {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isOSDType(coordinator.sneakPeekState(for: vm.screenUUID).type) && coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.showOpenNotchOSD] {
                        OpenNotchOSD(
                             type: coordinator.binding(for: vm.screenUUID).type,
                             value: coordinator.binding(for: vm.screenUUID).value,
                             icon: coordinator.binding(for: vm.screenUUID).icon,
                             accent: coordinator.binding(for: vm.screenUUID).accent
                        )
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        notificationHistoryButton
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    private var notificationHistoryButton: some View {
        let isSelected = coordinator.currentView == .notifications
        let unread = notificationManager.unreadCount

        return Button {
            withAnimation(.smooth) {
                coordinator.currentView = isSelected ? .home : .notifications
            }
        } label: {
            Capsule()
                .fill(isSelected ? Color(nsColor: .secondarySystemFill) : .black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: isSelected ? "bell.fill" : "bell")
                        .foregroundStyle(isSelected || unread > 0 ? .white : .white.opacity(0.8))
                        .imageScale(.medium)
                }
                .overlay(alignment: .topTrailing) {
                    if unread > 0 && !isSelected {
                        Text(unread > 9 ? "9+" : "\(unread)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, unread > 9 ? 3.5 : 0)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Color.effectiveAccent, in: Capsule())
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Notification History")
        .help("Notification History")
    }

    func isOSDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
