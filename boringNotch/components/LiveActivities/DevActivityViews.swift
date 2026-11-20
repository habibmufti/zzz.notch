//
//  DevActivityViews.swift
//  zzz.notch
//

import SwiftUI

/// Closed-notch pill for ongoing dev events: the notch becomes a face, one
/// eye on each side of the camera. Working: the eyes scan side to side and
/// blink. Waiting for you: they look up, widen and turn yellow. With more
/// than one ongoing event, the count sits beside the right eye.
struct DevActivityLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = DevActivityStore.shared

    private var itemSize: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        let waiting = store.waitingCount > 0
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack {
                AgentEye(size: itemSize, waiting: waiting, time: t)

                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

                AgentEye(size: itemSize, waiting: waiting, time: t)
                    .overlay(alignment: .bottomTrailing) {
                        if store.items.count > 1 {
                            Text("\(store.items.count)")
                                .font(.system(size: itemSize * 0.38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                                .offset(x: itemSize * 0.15, y: itemSize * 0.1)
                        }
                    }
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .animation(.spring(duration: 0.4), value: waiting)
    }
}

private struct AgentEye: View {
    let size: CGFloat
    let waiting: Bool
    let time: TimeInterval

    private static let lavender = Color(red: 0.80, green: 0.78, blue: 0.98)

    var body: some View {
        // Blink for ~0.14s every 3.7s; waiting eyes breathe instead of scanning.
        let blinking = time.truncatingRemainder(dividingBy: 3.7) < 0.14
        let width = size * 0.34
        let height = size * (waiting ? 0.9 + 0.06 * sin(time * 3) : 0.72) * (blinking ? 0.15 : 1)
        let dx = waiting ? 0 : sin(time * 1.4) * size * 0.16
        let dy = waiting ? -size * 0.06 : 0

        Capsule()
            .fill(waiting ? DevEventStatus.wait.color : Self.lavender)
            .frame(width: width, height: height)
            .offset(x: dx, y: dy)
            .frame(width: size, height: size)
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
