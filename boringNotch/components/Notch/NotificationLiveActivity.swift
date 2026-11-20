//
//  NotificationLiveActivity.swift
//  boringNotch
//

import SwiftUI

private struct NotificationSourceIcon: View {
    let notification: SystemNotification
    let size: CGFloat

    var body: some View {
        if let status = notification.status {
            // Dev events: the session's mascot reacts instead of a static icon.
            MascotView(look: MascotLook(id: notification.id)) { status.mascotMood }
                .frame(width: size, height: size)
        } else if let symbol = notification.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(notification.status?.color ?? .white)
                .frame(width: size, height: size)
        } else if let bundleID = notification.bundleID {
            appIcon(for: bundleID)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "bell")
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
        }
    }
}

struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification

    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    /// Mascots need a 16 px multiple to stay crisp, so dev events get a
    /// larger slot than app icons.
    private var itemSize: CGFloat {
        Self.slotSize(for: notification, notchHeight: vm.effectiveClosedNotchHeight)
    }

    static func slotSize(for notification: SystemNotification, notchHeight: CGFloat) -> CGFloat {
        notification.status != nil
            ? DevActivityLiveActivity.mascotSize(notchHeight: notchHeight)
            : max(0, notchHeight - 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            pill
            // Dev events grow the pill downward with their message, so a
            // "Done" is noticed without hovering.
            if notification.status != nil {
                peek
            }
        }
        .onAppear { pulse() }
        .onChange(of: notification.id) { _, _ in pulse() }
    }

    private var peek: some View {
        HStack(spacing: 6) {
            if let title = notification.title {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(dotColor)
            }
            if let body = notification.body {
                Text(body).foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top + 2 * itemSize + 16)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var pill: some View {
        HStack {
            NotificationSourceIcon(notification: notification, size: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            ZStack {
                Circle()
                    .stroke(dotColor, lineWidth: 1.5)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }

    private var dotColor: Color {
        notification.status?.color ?? Color.effectiveAccent
    }

    private func pulse() {
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }
}

struct NotificationExpandedView: View {
    @ObservedObject private var manager = SystemNotificationManager.shared
    let notification: SystemNotification

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openSourceApp) {
                HStack(alignment: .center, spacing: 12) {
                    NotificationSourceIcon(notification: notification, size: notification.status != nil ? 48 : 46)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(notification.appName ?? "Notification")
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)

                            Text(notification.receivedAt, style: .relative)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }

                        if let title = notification.title, title != notification.appName {
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }

                        if let subtitle = notification.subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let body = notification.body {
                            Text(body)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(notification.appName ?? "App") notification")
            .accessibilityHint("Opens \(notification.appName ?? "the app")")

            HStack(spacing: 4) {
                if !manager.queuedNotifications.isEmpty {
                    Button {
                        manager.showNextQueued()
                    } label: {
                        Text("+\(manager.queuedNotifications.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show next queued notification")
                }

                Button {
                    manager.dismissActive(token: notification.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.trailing, 4)
        }
        .onAppear { manager.holdActive() }
        .onDisappear { manager.resumeDismiss() }
    }

    private func openSourceApp() {
        Task {
            guard await manager.open(notification) else { return }
            manager.dismissActive(token: notification.id)
        }
    }
}
