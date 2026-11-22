//
//  AnimatedFace.swift
//  zzz.notch
//
//  Procedural agent face rendered in a dropped chin below the camera.
//  Springs smoothly between moods (idle, working, waiting, done, sleepy, sleep).
//

import SwiftUI

enum AgentFaceMood: String, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case waiting
    case done
    case sleepy
    case sleep

    static let sleepyAfterSeconds: TimeInterval = 60
    static let sleepAfterSeconds: TimeInterval = 180

    static func idleMood(elapsedSeconds: TimeInterval) -> AgentFaceMood {
        if elapsedSeconds >= sleepAfterSeconds { return .sleep }
        if elapsedSeconds >= sleepyAfterSeconds { return .sleepy }
        return .idle
    }

    static func resolve(
        items: [SystemNotification],
        celebratingUntil: [String: Date],
        now: Date = Date()
    ) -> AgentFaceMood {
        if items.contains(where: { $0.status == .wait }) {
            return .waiting
        }
        if items.contains(where: { $0.status == .run }) {
            return .working
        }
        if items.contains(where: { item in
            if let until = celebratingUntil[item.id], until > now { return true }
            return item.status == .ok
        }) {
            return .done
        }
        if let latest = items.map(\.receivedAt).max() {
            return idleMood(elapsedSeconds: max(0, now.timeIntervalSince(latest)))
        }
        return .idle
    }
}

/// Every pose is a small vector of normalized numbers; the canvas only draws these.
struct AgentFacePose: Equatable, Sendable {
    var eyeW: CGFloat
    var eyeH: CGFloat
    var lookX: CGFloat
    var lookY: CGFloat
    /// 0 hidden … 1 full wavy working mouth.
    var mouth: CGFloat
    /// 0 lavender … 1 alert yellow.
    var hue: Double
    /// 0 normal … 1 celebratory mint/smile.
    var happy: Double

    static func target(_ mood: AgentFaceMood) -> AgentFacePose {
        switch mood {
        case .idle:
            AgentFacePose(eyeW: 0.30, eyeH: 0.70, lookX: 0, lookY: 0, mouth: 0, hue: 0, happy: 0)
        case .working:
            AgentFacePose(eyeW: 0.30, eyeH: 0.62, lookX: -0.12, lookY: -0.04, mouth: 1, hue: 0, happy: 0)
        case .waiting:
            AgentFacePose(eyeW: 0.34, eyeH: 0.85, lookX: 0, lookY: -0.10, mouth: 0, hue: 1, happy: 0)
        case .done:
            AgentFacePose(eyeW: 0.34, eyeH: 0.56, lookX: 0, lookY: -0.04, mouth: 0, hue: 0, happy: 1)
        case .sleepy:
            AgentFacePose(eyeW: 0.42, eyeH: 0.16, lookX: 0, lookY: 0.10, mouth: 0, hue: 0, happy: 0)
        case .sleep:
            AgentFacePose(eyeW: 0.42, eyeH: 0.05, lookX: 0, lookY: 0.14, mouth: 0, hue: 0, happy: 0)
        }
    }
}

/// Critically damped spring following the target pose each frame.
/// Kept non-`@Published` so stepping inside `TimelineView` never triggers extra
/// SwiftUI body invalidations.
final class AgentFaceEngine: ObservableObject {
    private(set) var pose: AgentFacePose
    private var velocity = [CGFloat](repeating: 0, count: 7)
    private var lastTimestamp: TimeInterval?

    init(initialMood: AgentFaceMood = .idle) {
        self.pose = .target(initialMood)
    }

    func step(to mood: AgentFaceMood, at timestamp: TimeInterval) -> AgentFacePose {
        let dt: CGFloat
        if let last = lastTimestamp {
            dt = CGFloat(min(max(timestamp - last, 0), 1.0 / 30.0))
        } else {
            dt = 0
        }
        lastTimestamp = timestamp

        let target = AgentFacePose.target(mood)
        var cur: [CGFloat] = [
            pose.eyeW, pose.eyeH, pose.lookX, pose.lookY,
            pose.mouth, CGFloat(pose.hue), CGFloat(pose.happy)
        ]
        let tgt: [CGFloat] = [
            target.eyeW, target.eyeH, target.lookX, target.lookY,
            target.mouth, CGFloat(target.hue), CGFloat(target.happy)
        ]

        let stiffness: CGFloat = 170
        let damping: CGFloat = 18
        for i in cur.indices {
            velocity[i] += (stiffness * (tgt[i] - cur[i]) - damping * velocity[i]) * dt
            cur[i] += velocity[i] * dt
        }

        pose = AgentFacePose(
            eyeW: max(0.05, cur[0]),
            eyeH: max(0.02, cur[1]),
            lookX: cur[2],
            lookY: cur[3],
            mouth: min(max(cur[4], 0), 1),
            hue: Double(min(max(cur[5], 0), 1)),
            happy: Double(min(max(cur[6], 0), 1))
        )
        return pose
    }

    func isSettled(for mood: AgentFaceMood) -> Bool {
        let target = AgentFacePose.target(mood)
        let diffs: [CGFloat] = [
            abs(pose.eyeW - target.eyeW),
            abs(pose.eyeH - target.eyeH),
            abs(pose.lookX - target.lookX),
            abs(pose.lookY - target.lookY),
            abs(pose.mouth - target.mouth),
            abs(CGFloat(pose.hue - target.hue)),
            abs(CGFloat(pose.happy - target.happy))
        ]
        let maxDiff = diffs.max() ?? 0
        let maxVel = velocity.map(abs).max() ?? 0
        return maxDiff < 0.005 && maxVel < 0.01
    }
}

struct AgentFaceCanvas: View {
    let moodProvider: (Date) -> AgentFaceMood
    @StateObject private var engine = AgentFaceEngine()

    init(mood: AgentFaceMood) {
        self.moodProvider = { _ in mood }
    }

    init(moodProvider: @escaping (Date) -> AgentFaceMood) {
        self.moodProvider = moodProvider
    }

    private func frameInterval(for mood: AgentFaceMood) -> Double {
        if !engine.isSettled(for: mood) { return 1.0 / 30.0 }
        switch mood {
        case .working, .waiting, .done:
            return 1.0 / 30.0
        case .idle, .sleepy:
            return 1.0 / 20.0
        case .sleep:
            return 1.0 / 6.0
        }
    }

    var body: some View {
        let currentMood = moodProvider(Date())
        TimelineView(.animation(minimumInterval: frameInterval(for: currentMood))) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let mood = moodProvider(now)
            let p = engine.step(to: mood, at: t)

            Canvas { ctx, size in
                let s = min(size.width, size.height)
                guard s > 0 else { return }

                // Base lavender (0.80, 0.78, 0.98) -> alert yellow (hue) or mint green (happy).
                let baseR = 0.80 + 0.20 * p.hue
                let baseG = 0.78 + 0.08 * p.hue
                let baseB = 0.98 - 0.80 * p.hue
                let r = baseR * (1 - p.happy) + 0.45 * p.happy
                let g = baseG * (1 - p.happy) + 0.94 * p.happy
                let b = baseB * (1 - p.happy) + 0.65 * p.happy
                let color = Color(red: r, green: g, blue: b)

                // Micro-motion: natural blink + idle drift + working glance + sleep breath.
                let blinking = mood != .sleep && mood != .sleepy
                    && t.truncatingRemainder(dividingBy: 3.3) < 0.13
                let glance = mood == .working
                    ? sin(t * 1.7) * 0.10
                    : (mood == .sleep ? 0 : sin(t * 0.6) * 0.02)
                let breathY = mood == .sleep ? sin(t * 1.1) * 0.015 : 0

                let eyeH = p.eyeH * (blinking ? 0.12 : 1)
                let cx = size.width / 2 + (p.lookX + glance) * s
                let cy = size.height * 0.42 + (p.lookY + breathY) * s
                let gap = s * 0.38

                for side in [-1.0, 1.0] {
                    let w = p.eyeW * s * 0.62
                    let h = eyeH * s * 0.62
                    let rect = CGRect(
                        x: cx + side * gap / 2 - w / 2,
                        y: cy - h / 2,
                        width: w,
                        height: h
                    )
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: min(w, h) / 2),
                        with: .color(color)
                    )
                }

                // Working wavy mouth: phase-shifted sine, fades cleanly with p.mouth.
                if p.mouth > 0.02 {
                    var path = Path()
                    let mw = s * 0.34
                    let my = cy + s * 0.32
                    for i in 0...40 {
                        let x = cx - mw / 2 + mw * CGFloat(i) / 40
                        let y = my + sin(Double(i) / 40 * .pi * 4 - t * 7) * s * 0.025 * p.mouth
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    ctx.stroke(
                        path,
                        with: .color(color.opacity(Double(p.mouth))),
                        style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round, lineJoin: .round)
                    )
                }

                // Celebratory smile arc when an agent finishes (`ok`).
                if p.happy > 0.05 {
                    let mw = s * 0.28
                    let my = cy + s * 0.29
                    var smile = Path()
                    smile.move(to: CGPoint(x: cx - mw / 2, y: my))
                    smile.addQuadCurve(
                        to: CGPoint(x: cx + mw / 2, y: my),
                        control: CGPoint(x: cx, y: my + s * 0.12 * CGFloat(p.happy))
                    )
                    ctx.stroke(
                        smile,
                        with: .color(color.opacity(p.happy)),
                        style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round)
                    )
                }
            }
        }
    }
}

/// Full procedural face sitting in a dropped chin directly below the camera cutout.
struct AgentFaceDroppedChinView: View {
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    let moodProvider: (Date) -> AgentFaceMood

    static let faceHeight: CGFloat = 72
    static let faceWidth: CGFloat = 128

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: max(Self.faceWidth, cameraWidth), height: cameraHeight)

            AgentFaceCanvas(moodProvider: moodProvider)
                .frame(width: Self.faceWidth, height: Self.faceHeight)
        }
    }
}

/// Closed-notch Dev live activity using the full dropped-chin agent face.
struct DevAgentFaceLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = DevActivityStore.shared
    let cameraHeight: CGFloat

    var body: some View {
        AgentFaceDroppedChinView(
            cameraWidth: vm.closedNotchSize.width,
            cameraHeight: cameraHeight,
            moodProvider: { now in
                AgentFaceMood.resolve(
                    items: store.items,
                    celebratingUntil: store.celebratingUntil,
                    now: now
                )
            }
        )
    }
}

/// Closed-notch idle face using the same dropped-chin procedural face;
/// gradually drifts from `idle` → `sleepy` → `sleep` while undisturbed.
struct IdleAgentFaceView: View {
    @EnvironmentObject private var vm: BoringViewModel
    let cameraHeight: CGFloat
    @State private var idleSince = Date()

    var body: some View {
        AgentFaceDroppedChinView(
            cameraWidth: vm.closedNotchSize.width,
            cameraHeight: cameraHeight,
            moodProvider: { now in
                AgentFaceMood.idleMood(elapsedSeconds: max(0, now.timeIntervalSince(idleSince)))
            }
        )
        .onAppear {
            idleSince = Date()
        }
    }
}

/// Legacy preview/component wrapper kept for source compatibility.
struct AnimatedFace: View {
    var height: CGFloat = 72
    var width: CGFloat = 120
    var mood: AgentFaceMood = .idle

    var body: some View {
        AgentFaceCanvas(mood: mood)
            .frame(width: width, height: height)
    }
}

#Preview {
    ZStack {
        Color.black
        AnimatedFace(height: 72, width: 120, mood: .working)
    }
    .frame(width: 220, height: 110)
}
