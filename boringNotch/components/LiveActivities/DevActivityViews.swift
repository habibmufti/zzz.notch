//
//  DevActivityViews.swift
//  zzz.notch
//

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
                MascotView(look: MascotLook(id: item.id)) { store.mood(of: item, at: Date()) }
                    .frame(width: size, height: size)
            }
        }
    }
}

/// Open-notch Dev tab: every ongoing event; click opens its source.
struct DevActivityListView: View {
    @ObservedObject private var store = DevActivityStore.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(store.items) { item in
                    DevActivityRow(item: item)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DevActivityRow: View {
    @ObservedObject private var store = DevActivityStore.shared
    let item: SystemNotification

    var body: some View {
        HStack(spacing: 10) {
            MascotView(look: MascotLook(id: item.id)) { store.mood(of: item, at: Date()) }
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
                        Spacer(minLength: 4)
                        Text(item.receivedAt, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    if let body = item.body {
                        Text(body)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let detail = item.subtitle {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
