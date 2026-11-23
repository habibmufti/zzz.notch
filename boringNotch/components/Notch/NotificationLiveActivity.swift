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

    struct PeekContent: Equatable {
        let title: String?
        let source: String?
        let body: String?
    }

    static func peekContent(for notification: SystemNotification) -> PeekContent? {
        let cleanedTitle = notification.title.map(DevText.cleanTitle)
        let title = cleanedTitle ?? notification.appName
        let source = notification.appName.flatMap { $0 == title ? nil : $0 }

        let body: String?
        if notification.status != nil {
            body = notification.body
        } else if let subtitle = notification.subtitle, let bodyText = notification.body {
            body = "\(subtitle) · \(bodyText)"
        } else {
            body = notification.body ?? notification.subtitle
        }

        guard title != nil || body != nil else { return nil }
        return PeekContent(title: title, source: source, body: body)
    }

    var body: some View {
        VStack(spacing: 0) {
            pill
            // Grow the closed pill downward with the notification preview so
            // every notification (dev and mirrored system banners) is readable
            // without hovering.
            if let content = Self.peekContent(for: notification) {
                peek(content)
            }
        }
        .onAppear { pulse() }
        .onChange(of: notification.id) { _, _ in pulse() }
    }

    private func peek(_ content: PeekContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = content.title {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(dotColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let source = content.source {
                        Text(source)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
            if let bodyText = content.body {
                Text(bodyText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top + 2 * itemSize + 16)
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
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = SystemNotificationManager.shared
    @ObservedObject private var askCenter = DevAskCenter.shared
    let notification: SystemNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card
            // A dev tool asking a question: answer it right here.
            if let ask = askCenter.pending[notification.id] {
                DevAskView(ask: ask)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { manager.holdActive() }
        .onDisappear { manager.resumeDismiss() }
    }

    private var card: some View {
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

                        if let title = notification.title.map(DevText.cleanTitle), title != notification.appName {
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
                    manager.dismissActive(
                        token: notification.id,
                        dismissNative: true,
                        removeFromHistory: true
                    )
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
    }

    private func openSourceApp() {
        Task {
            guard await manager.open(notification) else { return }
            manager.dismissActive(token: notification.id, removeFromHistory: true)
            vm.close()
        }
    }
}

private struct NotificationHistoryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Open-notch Notification History list: shows recent notifications captured
/// while zzz.notch was running (up to 50 items, retained for 24 hours).
struct NotificationHistoryView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = SystemNotificationManager.shared
    @State private var contentHeight: CGFloat = 120
    /// High-water mark while open so deleting an item does not shrink the notch
    /// out from under the cursor and close it.
    @State private var minOpenHeight: CGFloat = 0

    private var maxScrollHeight: CGFloat { max(140, devTabNotchHeight - 58) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if manager.history.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(manager.history) { entry in
                            NotificationHistoryRow(
                                entry: entry,
                                showUnreadDot: !entry.isRead,
                                onOpen: { openEntry(entry) },
                                onRemove: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        manager.removeFromHistory(id: entry.id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: NotificationHistoryHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .frame(
                    height: min(max(max(contentHeight, minOpenHeight), 96), maxScrollHeight),
                    alignment: .top
                )
                .onPreferenceChange(NotificationHistoryHeightKey.self) { height in
                    guard height > 0 else { return }
                    contentHeight = height
                    minOpenHeight = max(minOpenHeight, height)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            manager.pruneExpiredHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(manager.history.isEmpty ? "NOTIFICATIONS" : "NOTIFICATIONS · \(manager.history.count)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            Spacer()

            if !manager.history.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        manager.clearHistory()
                    }
                } label: {
                    Text("Clear all")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No recent notifications")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Notifications captured while zzz.notch is running stay here for 24 hours.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .padding(.horizontal, 16)
    }

    private func openEntry(_ entry: NotificationHistoryEntry) {
        Task {
            let opened = await manager.openHistoryEntry(entry)
            if opened {
                vm.close()
            }
        }
    }
}

private struct NotificationHistoryRow: View {
    let entry: NotificationHistoryEntry
    let showUnreadDot: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var notification: SystemNotification { entry.asNotification }

    private var primaryTitle: String {
        entry.displayTitle
    }

    private var sourceLabel: String? {
        entry.displaySource
    }

    private var messageText: String? {
        entry.displayMessage
    }

    private var accentColor: Color {
        entry.status?.color ?? Color.effectiveAccent
    }

    var body: some View {
        HStack(spacing: 10) {
            NotificationSourceIcon(
                notification: notification,
                size: entry.status != nil ? 32 : 28
            )
            .frame(width: 32, height: 32)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if showUnreadDot {
                            Circle()
                                .fill(accentColor)
                                .frame(width: 5, height: 5)
                        }
                        Text(primaryTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if let sourceLabel {
                            Text(sourceLabel)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if let status = entry.status {
                            Text(status.label)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(status.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(status.color.opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                        Spacer(minLength: 4)
                        Text(entry.receivedAt, style: .relative)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    if let messageText {
                        Text(messageText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(hovering ? 0.14 : 0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from history")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(hovering ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
    }
}

private extension NotificationHistoryEntry {
    var displayTitle: String {
        title.map(DevText.cleanTitle) ?? appName ?? "Notification"
    }

    var displaySource: String? {
        guard let appName, appName != displayTitle else { return nil }
        return appName
    }

    var displayMessage: String? {
        if status != nil {
            return body
        }
        if let subtitle, let body {
            return "\(subtitle) · \(body)"
        }
        return body ?? subtitle
    }
}

/// Compact strip of the top 3 recent notifications shown under Music on Home.
struct HomeRecentNotificationsView: View {
    static let maxVisible = 3

    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var manager = SystemNotificationManager.shared

    static func visibleEntries(from history: [NotificationHistoryEntry]) -> [NotificationHistoryEntry] {
        Array(history.prefix(maxVisible))
    }

    var body: some View {
        let entries = Self.visibleEntries(from: manager.history)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, 4)

                HStack(spacing: 6) {
                    Text("NOTIFICATIONS · \(manager.history.count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    if manager.history.count > Self.maxVisible {
                        Button {
                            withAnimation(.smooth) {
                                coordinator.currentView = .notifications
                            }
                        } label: {
                            Text("View all")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            manager.clearHistory()
                        }
                    } label: {
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 4) {
                    ForEach(entries) { entry in
                        HomeNotificationCompactRow(
                            entry: entry,
                            onOpen: {
                                Task {
                                    let opened = await manager.openHistoryEntry(entry)
                                    if opened {
                                        vm.close()
                                    }
                                }
                            },
                            onRemove: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    manager.removeFromHistory(id: entry.id)
                                }
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct HomeNotificationCompactRow: View {
    let entry: NotificationHistoryEntry
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var accentColor: Color {
        entry.status?.color ?? Color.effectiveAccent
    }

    var body: some View {
        HStack(spacing: 8) {
            NotificationSourceIcon(
                notification: entry.asNotification,
                size: entry.status != nil ? 20 : 18
            )
            .frame(width: 20, height: 20)

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if !entry.isRead {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 4.5, height: 4.5)
                    }
                    Text(entry.displayTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let source = entry.displaySource {
                        Text(source)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let status = entry.status {
                        Text(status.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(status.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(status.color.opacity(0.14), in: Capsule())
                            .fixedSize()
                    }
                    if let message = entry.displayMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Text(entry.receivedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(.white.opacity(hovering ? 0.14 : 0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from history")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(hovering ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}
