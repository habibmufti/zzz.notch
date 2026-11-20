//
//  DevActivityViews.swift
//  zzz.notch
//

import SwiftUI

/// Closed-notch pill for ongoing dev events: a status glyph on the left,
/// the number of ongoing events on the right.
struct DevActivityLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = DevActivityStore.shared

    private var itemSize: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        HStack {
            Group {
                if store.waitingCount > 0 {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: itemSize * 0.55, weight: .semibold))
                        .foregroundStyle(DevEventStatus.wait.color)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DevEventStatus.run.color)
                }
            }
            .frame(width: itemSize, height: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            Text("\(store.items.count)")
                .font(.system(size: itemSize * 0.6, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(store.waitingCount > 0 ? DevEventStatus.wait.color : .white)
                .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
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
            Group {
                if item.status == .run {
                    ProgressView().controlSize(.small).tint(DevEventStatus.run.color)
                } else {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(DevEventStatus.wait.color)
                }
            }
            .frame(width: 18)

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
