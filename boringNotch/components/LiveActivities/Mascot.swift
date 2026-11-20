//
//  Mascot.swift
//  zzz.notch
//
//  16x16 pixel mascots for ongoing dev events. Every frame is a pure function
//  of (mood, kind, time, seed): breathing, hashed blinks, humanised typing
//  bursts, a waiting jump cycle, confetti, drifting z's. Drawn into a 16x16
//  CGImage and shown on a CALayer with nearest-neighbour scaling, which is
//  far cheaper than redrawing a SwiftUI Canvas 20 times a second.
//

import AppKit
import SwiftUI

enum MascotMood { case idle, working, waiting, done, sleep }
enum MascotKind: CaseIterable { case blob, robot, cat }

/// Stable per-id look: the same session keeps its character and colour.
struct MascotLook: Equatable {
    let kind: MascotKind
    let hue: Double
    let seed: Int

    init(id: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325                   // FNV-1a
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        kind = MascotKind.allCases[Int(h % 3)]
        hue = Double((h / 3) % 360) / 360
        seed = Int(truncatingIfNeeded: h >> 8) & 0xffff
    }
}

// MARK: - timing helpers

private func hash01(_ n: Int) -> Double {
    var x = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 29; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 32
    return Double(x % 10_000) / 10_000
}

/// Short blink at a random moment inside each ~3.5 s slot.
private func isBlinking(_ t: Double, seed: Int) -> Bool {
    let slot = Int(floor(t / 3.5)), local = t - Double(slot) * 3.5
    let at = 0.4 + hash01(slot &+ seed) * 2.6
    return local > at && local < at + 0.13
}

// MARK: - frame model

private struct MascotFrame {
    var px = [Character?](repeating: nil, count: 256)
    mutating func set(_ x: Int, _ y: Int, _ c: Character?) {
        guard (0..<16).contains(x), (0..<16).contains(y) else { return }
        px[y * 16 + x] = c
    }
    mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Character) {
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 { for x in x0...x1 { set(x, y, c) } }
    }
}

private enum Eyes { case open, closed, wide, happy, down }

private struct Pose {
    var dy = 0          // whole-body vertical offset (jump)
    var squash = 0      // 0 normal … 3 flat (sploot)
    var eyes = Eyes.open
    var lookX = 0, lookY = 0
    var feet = true
    var antenna: Character = "G"
}

// MARK: - drawing

private enum Draw {
    static func body(_ f: inout MascotFrame, _ p: Pose, kind: MascotKind) {
        let top = 4 + p.squash + p.dy, bottom = 13 + p.dy
        let widen = p.squash >= 2 ? 1 : 0
        let l = 3 - widen, r = 12 + widen
        f.rect(l + 1, top, r - 1, top, "D")
        f.rect(l, top + 1, r, bottom, "D")
        f.rect(l + 1, top + 1, r - 1, bottom - 1, "B")
        if kind != .robot {                                    // rounded shoulders
            f.set(l, top + 1, nil); f.set(r, top + 1, nil)
            f.set(l + 1, top + 1, "D"); f.set(r - 1, top + 1, "D")
        }
        f.rect(l + 2, top + 1, l + 3, top + 1, "H")            // highlight
        if p.feet { f.rect(4, bottom + 1, 5, bottom + 1, "D"); f.rect(10, bottom + 1, 11, bottom + 1, "D") }

        switch kind {
        case .blob: break
        case .robot:
            f.rect(7, top - 2, 8, top - 1, "D")                // antenna
            f.rect(7, top - 3, 8, top - 3, p.antenna)
            f.rect(l + 1, top + 3, r - 1, top + 5, "K")         // visor
        case .cat:
            f.set(l + 1, top - 2, "D"); f.set(l + 2, top - 1, "D"); f.set(l + 1, top - 1, "P")
            f.set(r - 1, top - 2, "D"); f.set(r - 2, top - 1, "D"); f.set(r - 1, top - 1, "P")
            f.rect(l - 2, top + 6, l - 1, top + 6, "D"); f.rect(r + 1, top + 6, r + 2, top + 6, "D")  // whiskers
            f.rect(7, top + 6, 8, top + 6, "P")                 // nose
        }
    }

    static func eyes(_ f: inout MascotFrame, _ p: Pose, kind: MascotKind) {
        let row = 8 + p.dy + (p.squash >= 2 ? p.squash - 1 : 0) + p.lookY
        let ink: Character = kind == .robot ? "S" : "K"
        for (i, x0) in [6, 9].enumerated() {
            let x = x0 + p.lookX
            switch p.eyes {
            case .open:   f.rect(x, row, x, row + 1, ink)
            case .down:   f.set(x, row + 1, ink); f.set(x, row + 2, ink)
            case .closed: f.rect(x - (i == 0 ? 1 : 0), row + 1, x + (i == 0 ? 0 : 1), row + 1, ink)
            case .wide:
                f.rect(x - 1 + i, row - 1, x + i, row + 1, ink)
                if kind != .robot { f.set(x - 1 + i, row - 1, "W") }
            case .happy:
                let hx = i == 0 ? 5 : 10
                f.set(hx - 1, row + 1, ink); f.set(hx, row, ink); f.set(hx + 1, row + 1, ink)
            }
        }
    }
}

// MARK: - scenes

private enum MascotScene {
    static func render(_ mood: MascotMood, kind: MascotKind, t: Double, seed: Int, headphones: Bool) -> MascotFrame {
        var f = MascotFrame()
        var p = Pose()
        var front: ((inout MascotFrame) -> Void)?
        var over: ((inout MascotFrame) -> Void)?

        switch mood {
        case .idle:
            if headphones {                                              // vibing: nod on the beat, eyes ^ ^
                p.squash = Int(t * 4) % 2
                p.eyes = isBlinking(t, seed: seed) ? .closed : .happy
            } else {
                p.squash = sin(t * 2 * .pi / 3.2) > 0.75 ? 1 : 0       // slow breath
                p.lookX = [-1, 0, 0, 1, 0][Int(hash01(Int(t / 2.2) &+ seed) * 5)]
                p.eyes = isBlinking(t, seed: seed) ? .closed : .open
            }

        case .working:
            let k = Int(t * 9)                                           // keystroke clock
            let thinking = hash01(Int(t * 1.3) &+ seed &+ 77) < 0.2      // pause bursts
            p.eyes = isBlinking(t, seed: seed) ? .closed : (thinking ? .open : .down)
            p.lookY = thinking ? -1 : 0
            p.lookX = thinking ? (hash01(Int(t * 1.3) &+ seed) < 0.5 ? -1 : 1) : 0
            p.antenna = k % 4 < 2 ? "S" : "D"
            let leftHand = hash01(k &+ seed) < 0.5
            front = { f in
                f.rect(3, 11, 12, 11, "L"); f.rect(2, 12, 13, 13, "L")   // laptop
                f.rect(4, 12, 11, 12, "S")
                if thinking {
                    f.set(4, 10, "B"); f.set(11, 10, "B")
                } else {
                    for x in 4...11 where hash01(k &* 31 &+ x) < 0.25 { f.set(x, 12, "C") }
                    f.set(leftHand ? 5 : 4, 10, "B"); f.set(leftHand ? 10 : 11, 10, "B")
                }
            }

        case .waiting:
            let u = (t + Double(seed % 7) * 0.3).truncatingRemainder(dividingBy: 3.5)
            p.eyes = .wide
            p.antenna = Int(t * 4) % 2 == 0 ? "Y" : "D"
            switch u {
            case ..<1.8:  p.lookX = u < 0.9 ? -1 : 1
            case ..<2.1:  p.squash = 1                                    // anticipation
            case ..<2.7:  p.dy = -Int((4 * sin(.pi * (u - 2.1) / 0.6)).rounded()); p.feet = u > 2.6
            case ..<2.85: p.squash = 1                                    // landing
            default: break
            }
            let bang = Int(t * 4) % 2 == 0 || (u >= 2.1 && u < 2.7)
            let dy = p.dy
            over = { f in
                guard bang else { return }
                let y = 1 + min(0, dy / 2)
                f.rect(14, y, 14, y + 2, "Y"); f.set(14, y + 4, "Y")
            }

        case .done:
            let v = t.truncatingRemainder(dividingBy: 1.2)
            p.dy = v < 0.5 ? -Int((3 * sin(.pi * v / 0.5)).rounded()) : 0
            p.squash = v >= 0.5 && v < 0.6 ? 1 : 0
            p.eyes = .happy
            over = { f in
                let colors: [Character] = ["Y", "S", "P", "G"]
                for i in 0..<7 {
                    let x = Int(hash01(i &* 13 &+ seed) * 16)
                    let y = Int((t * 7 + hash01(i &* 7) * 16).truncatingRemainder(dividingBy: 16))
                    if y < 9 { f.set(x, y, colors[i % 4]) }
                }
            }

        case .sleep:
            p.squash = sin(t * 2 * .pi / 3) > 0 ? 2 : 3                  // breathing sploot
            p.eyes = .closed
            p.feet = false
            p.antenna = "D"
            over = { f in
                for i in 0..<3 {
                    let ph = (t / 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    guard ph < 0.85 else { continue }
                    let y = 5 - Int(ph * 6), x = 11 + Int((sin(ph * 6) * 1.2).rounded())
                    if i == 0 {
                        f.rect(x, y, x + 3, y, "Y"); f.set(x + 2, y + 1, "Y"); f.set(x + 1, y + 2, "Y"); f.rect(x, y + 3, x + 3, y + 3, "Y")
                    } else {
                        f.rect(x, y, x + 1, y, "Y"); f.set(x, y + 1, "Y"); f.rect(x, y + 2, x + 1, y + 2, "Y")
                    }
                }
            }
        }

        Draw.body(&f, p, kind: kind)
        if headphones {
            let top = 4 + p.squash + p.dy, widen = p.squash >= 2 ? 1 : 0
            let l = 3 - widen, r = 12 + widen
            f.rect(l + 1, top - 1, r - 1, top - 1, "N")                   // band
            f.rect(l - 1, top + 2, l, top + 5, "M"); f.rect(r, top + 2, r + 1, top + 5, "M")  // ear cups
            f.rect(l - 1, top + 2, l - 1, top + 5, "N"); f.rect(r + 1, top + 2, r + 1, top + 5, "N")
        }
        Draw.eyes(&f, p, kind: kind)
        front?(&f)
        over?(&f)
        return f
    }
}

// MARK: - image

private enum MascotImage {
    typealias RGBA = (UInt8, UInt8, UInt8, UInt8)

    static func palette(_ look: MascotLook) -> [Character: RGBA] {
        func hsb(_ s: CGFloat, _ b: CGFloat) -> RGBA {
            let c = NSColor(hue: look.hue, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
            return (UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255), 255)
        }
        return [
            "B": hsb(look.kind == .robot ? 0.15 : 0.35, 0.96), "H": hsb(0.08, 1), "D": hsb(0.55, 0.52),
            "K": (26, 23, 41, 255), "W": (255, 255, 255, 255), "L": (140, 140, 140, 255),
            "S": (140, 224, 255, 255), "C": (217, 247, 255, 255), "Y": (255, 214, 64, 255),
            "P": (255, 153, 179, 255), "G": (128, 242, 140, 255),
            "N": (58, 58, 70, 255), "M": (235, 84, 96, 255),
        ]
    }

    static func make(_ frame: MascotFrame, palette: [Character: RGBA]) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            guard let key = frame.px[i], let (r, g, b, a) = palette[key] else { continue }
            bytes[i * 4] = r; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = b; bytes[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - view

/// Animates while it is in a visible window; `mood` is re-read every frame so
/// time-based transitions (idle → sleep) need no extra plumbing.
final class MascotLayerView: NSView {
    var look = MascotLook(id: "") { didSet { if look != oldValue { palette = MascotImage.palette(look) } } }
    var mood: @MainActor () -> MascotMood = { .idle }
    var headphones: @MainActor () -> Bool = { false }

    private lazy var palette = MascotImage.palette(look)
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let window, window.occlusionState.contains(.visible) else { return }
        let t = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
        let frame = MascotScene.render(mood(), kind: look.kind, t: t, seed: look.seed, headphones: headphones())
        layer?.contents = MascotImage.make(frame, palette: palette)
    }
}

struct MascotView: NSViewRepresentable {
    let look: MascotLook
    let mood: @MainActor () -> MascotMood
    /// Defaults to "music is playing", so every mascot listens along.
    var headphones: @MainActor () -> Bool = { MusicManager.shared.isPlaying }

    func makeNSView(context: Context) -> MascotLayerView { MascotLayerView(frame: .zero) }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        view.look = look
        view.mood = mood
        view.headphones = headphones
    }
}
