//
//  DevActivityViews.swift
//  zzz.notch
//

import Defaults
import SwiftUI

/// Closed-notch pill for ongoing dev events: one pixel mascot per id,
/// alternating left and right of the camera, two per side at most.
struct DevActivityLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = DevActivityStore.shared

    static let perSide = 2
    static let spacing: CGFloat = 2

    /// Integer multiple of the 16 px sprite so pixels stay square.
    static func mascotSize(notchHeight: CGFloat) -> CGFloat {
        max(16, (notchHeight / 16).rounded(.down) * 16)
    }

    /// Width the pill adds on each side of the notch for `count` mascots.
    static func sideWidth(count: Int, notchHeight: CGFloat) -> CGFloat {
        let n = CGFloat(min((count + 1) / 2, perSide))
        return n * mascotSize(notchHeight: notchHeight) + max(0, n - 1) * spacing + 6
    }

    var body: some View {
        let size = Self.mascotSize(notchHeight: vm.effectiveClosedNotchHeight)
        let sideWidth = Self.sideWidth(count: store.items.count, notchHeight: vm.effectiveClosedNotchHeight)
        let shown = Array(store.items.prefix(Self.perSide * 2))
        let left = shown.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let right = shown.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let hidden = store.items.count - shown.count

        HStack(spacing: 0) {
            side(left, size: size).frame(width: sideWidth, alignment: .trailing)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            side(right, size: size)
                .overlay(alignment: .bottomTrailing) {
                    if hidden > 0 {
                        Text("+\(hidden)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: sideWidth, alignment: .leading)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }

    private func side(_ items: [SystemNotification], size: CGFloat) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(items) { item in
                MascotView(
                    look: MascotLook(id: item.id),
                    mood: { store.mood(of: item, at: Date()) },
                    activity: { mascotActivity(of: item) },
                    badge: { Defaults[.devSubagentBadge] ? (item.agents ?? 0) : 0 }
                )
                .frame(width: size, height: size)
            }
        }
    }
}

/// Pose for a row's `activity` param; unknown or missing values type.
private func mascotActivity(of item: SystemNotification) -> MascotActivity {
    MascotActivity(rawValue: item.activity ?? "") ?? .type
}

/// Open-notch Dev tab: every ongoing event; click opens its source.
/// Verbose: the session that most needs you gets a card, the rest one line each.
struct DevActivityListView: View {
    @ObservedObject private var store = DevActivityStore.shared
    @Default(.devVerboseCard) private var verboseCard

    var body: some View {
        let items = store.sortedItems
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                if verboseCard, let first = items.first {
                    VStack(alignment: .leading, spacing: 10) {
                        DevSessionCard(item: first)
                        if items.count > 1 {
                            DevSectionHeader("OTHER SESSIONS · CLICK TO OPEN")
                            VStack(spacing: 4) {
                                ForEach(items.dropFirst()) { item in
                                    DevCompactRow(item: item)
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(items) { item in
                            DevActivityRow(item: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: items.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DevActivityRow: View {
    @ObservedObject private var store = DevActivityStore.shared
    @ObservedObject private var askCenter = DevAskCenter.shared
    @Default(.devSubagentBadge) private var subagentBadge
    let item: SystemNotification
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                MascotView(
                    look: MascotLook(id: item.id),
                    mood: { store.mood(of: item, at: Date()) },
                    activity: { mascotActivity(of: item) },
                    badge: { Defaults[.devSubagentBadge] ? (item.agents ?? 0) : 0 }
                )
                .frame(width: 32, height: 32)

                Button {
                    Task { _ = await SystemNotificationManager.shared.open(item) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title ?? item.appName ?? "zzz")
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if let source = item.appName, source != item.title {
                                Text(source)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            if subagentBadge, let agents = item.agents, agents > 0 {
                                Text("\(agents) agents")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }
                            Spacer(minLength: 4)
                            Text(item.receivedAt, style: .relative)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                        if let line = item.prompt ?? item.body {
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // The current step only means something while it runs.
                        if item.status == .run, let detail = item.subtitle {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if hovering, let lines = store.recent[item.id], !lines.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(.tertiary)
                                            .frame(width: 3, height: 3)
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: hovering)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    store.remove(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            if let ask = askCenter.pending[item.id] {
                DevAskView(ask: ask)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
    }
}

/// Small caps label above a card section.
private struct DevSectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

private struct DevCardSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevSectionHeader(title)
            content
        }
    }
}

/// Detailed card for the session that most needs you (verbose Dev tab).
private struct DevSessionCard: View {
    @ObservedObject private var store = DevActivityStore.shared
    @ObservedObject private var askCenter = DevAskCenter.shared
    let item: SystemNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let prompt = item.prompt {
                DevCardSection("TASK") {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            switch item.status {
            case .run?: nowSection
            case .wait?: waitSection
            default: resultSection
            }
            if let step = item.step {
                DevCardSection("PLAN") {
                    Text(step)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if !agentLines.isEmpty {
                DevCardSection("AGENTS · \(agentLines.count) RUNNING") {
                    ForEach(Array(agentLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Image(systemName: "person.2")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text(line)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let lines = store.recent[item.id], !lines.isEmpty {
                DevCardSection("BEFORE THAT") {
                    ForEach(Array(lines.suffix(5).reversed().enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text(line)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 10) {
            MascotView(
                look: MascotLook(id: item.id),
                mood: { store.mood(of: item, at: Date()) },
                activity: { mascotActivity(of: item) },
                badge: { Defaults[.devSubagentBadge] ? (item.agents ?? 0) : 0 }
            )
            .frame(width: 32, height: 32)

            Button {
                Task { _ = await SystemNotificationManager.shared.open(item) }
            } label: {
                HStack(spacing: 6) {
                    Text(item.title ?? item.appName ?? "zzz")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    if let source = item.appName, source != item.title {
                        Text(source)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(item.receivedAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.remove(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private var nowSection: some View {
        DevCardSection("NOW") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: activitySymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DevEventStatus.run.color)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    if let headline = item.now ?? item.subtitle {
                        Text(headline)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                    }
                    if let intent = item.intent {
                        Text(intent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let command = item.command {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var waitSection: some View {
        DevCardSection("WAITING FOR YOU") {
            if let body = item.body {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let ask = askCenter.pending[item.id] {
                DevAskView(ask: ask)
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let body = item.body {
            DevCardSection("LAST RESULT") {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var activitySymbol: String {
        switch MascotActivity(rawValue: item.activity ?? "") {
        case .type: "pencil"
        case .search: "magnifyingglass"
        case .build: "hammer"
        case .push: "paperplane"
        case .read: "doc.text"
        case nil: "terminal"
        }
    }

    /// `agentList` as non-empty trimmed lines.
    private var agentLines: [String] {
        (item.agentList ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One line for a session other than the card's; tap opens its source.
private struct DevCompactRow: View {
    let item: SystemNotification

    var body: some View {
        let title = item.title ?? item.appName ?? "zzz"
        let source = item.appName == title ? nil : item.appName
        let detail = [source, item.now ?? item.subtitle]
            .compactMap { $0 }
            .joined(separator: " · ")
        Button {
            Task { _ = await SystemNotificationManager.shared.open(item) }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill((item.status ?? .info).color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
