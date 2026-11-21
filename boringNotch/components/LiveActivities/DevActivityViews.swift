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

private struct DevContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Open-notch Dev tab: every ongoing event; click selects a session card,
/// clicking the card header or a row's arrow opens its source app.
struct DevActivityListView: View {
    @ObservedObject private var store = DevActivityStore.shared
    @Default(.devVerboseCard) private var verboseCard
    @State private var selectedID: String?
    @State private var contentHeight: CGFloat = 160

    private var maxScrollHeight: CGFloat { max(140, devTabNotchHeight - 58) }

    var body: some View {
        let items = store.sortedItems
        let active = selectedID.flatMap { id in items.first(where: { $0.id == id }) } ?? items.first
        let others = active.map { current in items.filter { $0.id != current.id } } ?? []

        ScrollView(.vertical, showsIndicators: false) {
            Group {
                if verboseCard, let current = active {
                    VStack(alignment: .leading, spacing: 10) {
                        DevSessionCard(item: current)
                        if !others.isEmpty {
                            DevSectionHeader("OTHER SESSIONS · \(others.count)")
                            VStack(spacing: 4) {
                                ForEach(others) { item in
                                    DevCompactRow(item: item) {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            selectedID = item.id
                                        }
                                    }
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
            .padding(.bottom, 4)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DevContentHeightKey.self, value: proxy.size.height)
                }
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: items.map(\.id))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: active?.id)
        }
        .frame(maxWidth: .infinity, height: min(max(contentHeight, 96), maxScrollHeight), alignment: .top)
        .onPreferenceChange(DevContentHeightKey.self) { height in
            if height > 0 { contentHeight = height }
        }
        // A session asking for input jumps back to the front card automatically.
        .onChange(of: items.first(where: { $0.status == .wait })?.id) { _, waitingID in
            if let waitingID { selectedID = waitingID }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let current = selectedID, !ids.contains(current) {
                selectedID = nil
            }
        }
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
                            Text(DevText.cleanTitle(item.title ?? item.appName ?? "zzz"))
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

/// Detailed card for the active session (verbose Dev tab).
private struct DevSessionCard: View {
    @ObservedObject private var store = DevActivityStore.shared
    @ObservedObject private var askCenter = DevAskCenter.shared
    let item: SystemNotification
    @State private var hoveringHeader = false

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
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.suffix(5).reversed().enumerated()), id: \.offset) { _, line in
                            let parsed = DevText.parseStep(line)
                            HStack(spacing: 6) {
                                if let tool = parsed.tool {
                                    Text(tool)
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                        .fixedSize()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 14)
                                }
                                Text(parsed.text)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
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
        let displayTitle = DevText.cleanTitle(item.title ?? item.appName ?? "zzz")
        let mood = store.mood(of: item, at: Date())
        let status = effectiveStatus(mood: mood)

        return HStack(spacing: 10) {
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
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    if let source = item.appName, source != displayTitle, source != item.title {
                        Text(source)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 5, height: 5)
                        Text(status.label)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(status.color)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.14), in: Capsule())
                    .fixedSize()

                    Spacer(minLength: 4)

                    if hoveringHeader {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.receivedAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(hoveringHeader ? 0.08 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringHeader = $0 }
            .help("Open source app")

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

    private func effectiveStatus(mood: MascotMood) -> (label: String, color: Color) {
        if mood == .done { return ("Done", DevEventStatus.ok.color) }
        if mood == .sleep { return ("Sleeping", DevEventStatus.idle.color) }
        let st = item.status ?? .info
        return (st.label, st.color)
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
                        Text(DevText.shortenPaths(in: command))
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
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(3)
            }
            if let ask = askCenter.pending[item.id] {
                DevAskView(ask: ask)
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        // "Idle"/"Working" are placeholders, not results.
        if let body = item.body, !["Idle", "Working", "Done"].contains(body) {
            let accent: Color = item.status == .fail ? DevEventStatus.fail.color : DevEventStatus.ok.color
            DevCardSection("LAST RESULT") {
                Text(body)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(accent.opacity(0.85))
                            .frame(width: 2.5)
                            .padding(.vertical, 5)
                            .padding(.leading, 6)
                    }
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

/// One line for a session other than the card's: clicking inspects it in the
/// card; the trailing arrow jumps straight to its source app.
private struct DevCompactRow: View {
    let item: SystemNotification
    let onSelect: () -> Void
    @State private var hovering = false
    @State private var hoveringOpen = false

    var body: some View {
        let title = DevText.cleanTitle(item.title ?? item.appName ?? "zzz")
        let source = (item.appName == title || item.appName == item.title) ? nil : item.appName
        let detail = [source, item.status == .run ? (item.now ?? item.subtitle) : nil]
            .compactMap { $0 }
            .joined(separator: " · ")

        HStack(spacing: 8) {
            Button(action: onSelect) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { _ = await SystemNotificationManager.shared.open(item) }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hoveringOpen ? .primary : .tertiary)
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(hoveringOpen ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringOpen = $0 }
            .help("Open source app")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(hovering ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}
