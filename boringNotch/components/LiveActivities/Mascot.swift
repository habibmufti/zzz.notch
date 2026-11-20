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
import Combine
import Defaults
import SwiftUI

enum MascotMood { case idle, working, waiting, done, sleep }
enum MascotKind: CaseIterable { case blob, robot, cat }
enum MascotActivity: String { case type, search, build, push, read }

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
    var headphonesDrop = 0  // headphones slipping down to the neck
}

// MARK: - music input

/// One-shot reactions: music events are shared by every mascot, `poke` is
/// per mascot (a click).
enum MascotReaction: Equatable { case newTrack, skip, pause, resume, poke }

/// Everything music-related a frame needs. `level` is 0…1 loudness.
struct MascotMusic {
    var listening = false
    var level = 0.0
    var reaction: MascotReaction?
    var age = 0.0           // seconds since `reaction`
    var gaze: Int?          // -1 / 0 / 1 toward the cursor while hovered
    static let reactionLength = 1.4
}

// MARK: - drawing

private enum Draw {
    static func note(_ f: inout MascotFrame, _ x: Int, _ y: Int, _ c: Character) {
        f.rect(x, y + 2, x + 1, y + 3, c); f.rect(x + 1, y, x + 1, y + 2, c); f.set(x + 2, y, c)
    }

    static func heart(_ f: inout MascotFrame, _ x: Int, _ y: Int, _ c: Character) {
        f.set(x, y, c); f.set(x + 2, y, c); f.rect(x, y + 1, x + 2, y + 1, c); f.set(x + 1, y + 2, c)
    }

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

    static func rocket(_ f: inout MascotFrame, x: Int, y: Int, flicker: Bool) {
        f.set(x, y - 3, "M")                                                     // nose
        f.rect(x - 1, y - 2, x + 1, y + 1, "W"); f.set(x, y - 1, "S")           // hull, porthole
        f.set(x - 2, y + 1, "M"); f.set(x + 2, y + 1, "M")                       // fins
        f.rect(x - 1, y + 2, x + 1, y + 2, "L")                                  // nozzle
        f.set(x, y + 3, "Y")                                                     // flame
        if flicker { f.set(x - 1, y + 3, "M"); f.set(x + 1, y + 3, "M"); f.set(x, y + 4, "Y") }
        else { f.set(x, y + 4, "M") }
    }

    /// 3x5 digit glyphs, row-major, bit set = lit.
    static let digits = [
        "111101101101111", "010110010010111", "111001111100111", "111001111001111", "101101111001001",
        "111100111001111", "111100111101111", "111001001001001", "111101111101111", "111101111001111",
    ]

    /// Count in the top-left corner (1…9; larger shows 9). The notch background is black, so no outline.
    static func badge(_ f: inout MascotFrame, _ n: Int) {
        for (i, c) in Array(digits[min(max(n, 1), 9)]).enumerated() where c == "1" {
            f.set(i % 3, i / 3, "Y")
        }
    }
}

// MARK: - scenes

private enum MascotScene {
    static func render(_ mood: MascotMood, kind: MascotKind, t: Double, seed: Int, music m: MascotMusic,
                       activity: MascotActivity, badge: Int) -> MascotFrame {
        var f = MascotFrame()
        var p = Pose()
        var front: ((inout MascotFrame) -> Void)?
        var over: ((inout MascotFrame) -> Void)?

        switch mood {
        case .idle:
            if m.listening {                                             // vibing to the actual loudness
                p.squash = m.level > 0.45 ? 1 : 0
                p.dy = m.level > 0.8 ? -1 : 0
                p.lookX = m.level > 0.65 ? (Int(t * 2) % 2 == 0 ? -1 : 1) : 0
                p.eyes = isBlinking(t, seed: seed) ? .closed : .happy
                let level = m.level
                over = { f in
                    guard level > 0.55 else { return }
                    let ph = (t / 1.6 + Double(seed % 5) / 5).truncatingRemainder(dividingBy: 1)
                    Draw.note(&f, 12 + Int((sin(ph * 9)).rounded()), 4 - Int(ph * 5), "Y")
                }
            } else {
                p.squash = sin(t * 2 * .pi / 3.2) > 0.75 ? 1 : 0       // slow breath
                p.lookX = [-1, 0, 0, 1, 0][Int(hash01(Int(t / 2.2) &+ seed) * 5)]
                p.eyes = isBlinking(t, seed: seed) ? .closed : .open
            }

        case .working:
            let k = Int(t * 9)                                           // keystroke clock
            let thinking = hash01(Int(t * 1.3) &+ seed &+ 77) < 0.2      // pause bursts
            p.antenna = m.listening && m.level > 0.6 ? "M" : (k % 4 < 2 ? "S" : "D")
            switch activity {
            case .type:
                p.eyes = isBlinking(t, seed: seed) ? .closed : (thinking ? .open : .down)
                p.lookY = thinking ? -1 : 0
                p.lookX = thinking ? (hash01(Int(t * 1.3) &+ seed) < 0.5 ? -1 : 1) : 0
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

            case .search:
                // magnifier sweeps across the lower body and dwells at both ends
                let slot = floor(t / 5), local = t - slot * 5
                let s = max(-1, min(1, sin(2 * .pi * t / 2.4) * 1.4))
                let x0 = 1 + Int(((s + 1) / 2 * 7).rounded())                 // lens left edge, 1…8
                let peering = local > 3 && local < 3.8 && hash01(Int(slot) &+ seed &+ 31) < 0.5
                p.eyes = peering ? .wide : (isBlinking(t, seed: seed) ? .closed : .open)
                p.lookX = x0 + 2 < 5 ? -1 : (x0 + 2 > 6 ? 1 : 0)
                let gy = 10
                front = { f in
                    f.rect(x0 + 1, gy, x0 + 3, gy, "L"); f.rect(x0, gy + 1, x0, gy + 3, "L")
                    f.rect(x0 + 4, gy + 1, x0 + 4, gy + 3, "L"); f.rect(x0 + 1, gy + 4, x0 + 3, gy + 4, "L")
                    f.rect(x0 + 1, gy + 1, x0 + 3, gy + 3, "C"); f.set(x0 + 1, gy + 1, "W")   // glass
                    f.set(x0 + 4, gy + 4, "D"); f.set(x0 + 5, gy + 5, "D")                     // handle
                }

            case .build:
                p.eyes = isBlinking(t, seed: seed) ? .closed : .down
                let sx = 7 + Int((2 * sin(2 * .pi * t / 1.2)).rounded())     // bowl sways 5…9
                front = { f in
                    f.rect(2, 11, 13, 11, "L"); f.rect(3, 12, 12, 13, "N")  // pot rim and body
                    f.rect(sx, 12, sx + 1, 12, "Y")                         // spoon bowl
                    let run = Double(12 - sx)                               // handle run, at least 3
                    for x in (sx + 2)...12 { f.set(x, Int((10 + Double(13 - x) * 2 / run).rounded()), "D") }
                    f.set(13, 10, "B")                                      // hand
                    for i in 0..<2 {
                        let ph = (t / 1.8 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                        guard ph < 0.9 else { continue }
                        let y = 9 - Int(ph * 7), x = 13 + (sin(ph * 6 + Double(i)) > 0 ? 1 : 0)
                        let c: Character = ph < 0.5 ? "W" : "C"
                        f.rect(x, y, x + 1, y, c); f.set(x, y - 1, c)
                    }
                }

            case .push:
                let ph = t.truncatingRemainder(dividingBy: 2.5) / 2.5
                p.lookY = -1                                                 // eyes up after the rocket
                p.eyes = isBlinking(t, seed: seed) ? .closed : .open
                if ph >= 0.15 && ph < 0.3 { p.squash = ph < 0.2 ? 2 : 1 }    // liftoff squash
                let rocketY: Int?
                if ph < 0.15 {
                    rocketY = 12                                             // parked on the right
                } else if ph < 0.55 {
                    let q = (ph - 0.15) / 0.4
                    rocketY = 12 - Int((q * q * 20).rounded())               // accelerating climb
                } else if ph < 0.85 {
                    rocketY = nil                                            // out of frame
                } else {
                    let q = (ph - 0.85) / 0.15
                    rocketY = 20 - Int((q * 8).rounded())                    // re-enters from below
                }
                let flicker = Int(t * 12) % 2 == 0
                front = { f in
                    if let y = rocketY { Draw.rocket(&f, x: 13, y: y, flicker: flicker) }
                }

            case .read:
                p.eyes = isBlinking(t, seed: seed) ? .closed : .down
                let flip = t.truncatingRemainder(dividingBy: 1.5) / 1.5      // page turns in the last fifth
                front = { f in
                    f.rect(1, 11, 14, 14, "P")                               // cover
                    f.rect(2, 11, 6, 13, "W"); f.rect(9, 11, 13, 13, "W")    // pages
                    f.rect(7, 11, 8, 13, "P")                                // spine
                    f.rect(3, 12, 5, 12, "L"); f.rect(10, 12, 12, 12, "L")   // text
                    guard flip >= 0.8 else { return }
                    let u = (flip - 0.8) / 0.2
                    let w = Int((5 * abs(cos(.pi * u))).rounded())
                    if u < 0.5 { f.rect(8, 11, 7 + w, 13, "W") }             // lifting off the right page
                    else { f.rect(8 - w, 11, 7, 13, "W") }                   // settling onto the left
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

        if let g = m.gaze, mood != .sleep {
            p.lookX = g
            if p.eyes == .down { p.eyes = .open }
        }
        if let r = m.reaction, m.age < MascotMusic.reactionLength {
            react(r, age: m.age, t: t, pose: &p, over: &over)
        }

        Draw.body(&f, p, kind: kind)
        let pausing = m.reaction == .pause && m.age < MascotMusic.reactionLength
        if m.listening || pausing {
            let top = 4 + p.squash + p.dy + p.headphonesDrop, widen = p.squash >= 2 ? 1 : 0
            let l = 3 - widen, r = 12 + widen
            f.rect(l + 1, top - 1, r - 1, top - 1, "N")                   // band
            f.rect(l - 1, top + 2, l, top + 5, "M"); f.rect(r, top + 2, r + 1, top + 5, "M")  // ear cups
            f.rect(l - 1, top + 2, l - 1, top + 5, "N"); f.rect(r + 1, top + 2, r + 1, top + 5, "N")
        }
        Draw.eyes(&f, p, kind: kind)
        front?(&f)
        over?(&f)
        if badge > 0 { Draw.badge(&f, badge) }                                   // count, always on top
        return f
    }

    /// Short override on top of whatever the mood is doing.
    private static func react(_ r: MascotReaction, age a: Double, t: Double, pose p: inout Pose,
                              over: inout ((inout MascotFrame) -> Void)?) {
        let hop = { (h: Double, len: Double) -> Int in a < len ? -Int((h * sin(.pi * a / len)).rounded()) : 0 }
        switch r {
        case .poke:                                                      // squish, then a happy hop + heart
            p.squash = a < 0.15 ? 2 : 0
            p.dy = a < 0.15 ? 0 : hop(3, 0.6)
            p.eyes = a < 0.15 ? .closed : .happy
            over = { f in Draw.heart(&f, 12, max(0, 3 - Int(a * 3)), "P") }
        case .newTrack, .resume:                                         // "ooh, a song"
            p.dy = hop(2, 0.5)
            p.eyes = .happy
            over = { f in Draw.note(&f, 12, max(0, 4 - Int(a * 4)), "Y"); Draw.note(&f, 1, max(0, 5 - Int(a * 3)), "S") }
        case .skip:                                                      // startled, looks around
            p.dy = hop(2, 0.35)
            p.eyes = .wide
            p.lookX = Int(a * 6) % 2 == 0 ? -1 : 1
            over = { f in f.rect(14, 1, 14, 3, "Y"); f.set(14, 5, "Y") }
        case .pause:                                                     // sad, headphones slide off
            p.eyes = .down
            p.squash = 1
            p.headphonesDrop = min(4, Int(a * 4))
        }
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

/// Shared music cues: loudness from the realtime visualizer tap (when it is
/// enabled and capturing) and one-shot track events from `MusicManager`.
@MainActor
final class MascotMusicCue {
    static let shared = MascotMusicCue()

    private(set) var reaction: MascotReaction?
    private(set) var reactionAt = Date.distantPast
    private var title = ""
    private var playing = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let music = MusicManager.shared
        title = music.songTitle
        playing = music.isPlaying
        music.$songTitle.removeDuplicates().dropFirst().sink { [weak self] new in
            MainActor.assumeIsolated { self?.titleChanged(to: new) }
        }.store(in: &cancellables)
        music.$isPlaying.removeDuplicates().dropFirst().sink { [weak self] now in
            MainActor.assumeIsolated { self?.playingChanged(to: now) }
        }.store(in: &cancellables)
    }

    private func titleChanged(to new: String) {
        defer { title = new }
        guard !new.isEmpty, !title.isEmpty else { return }
        // `@Published` fires before the store, so these still describe the old song.
        let music = MusicManager.shared
        let elapsed = music.elapsedTime + (playing ? Date().timeIntervalSince(music.timestampDate) * music.playbackRate : 0)
        let skipped = music.songDuration > 0 && elapsed < music.songDuration - 5
        fire(skipped ? .skip : .newTrack)
    }

    private func playingChanged(to now: Bool) {
        playing = now
        fire(now ? .resume : .pause)
    }

    private func fire(_ r: MascotReaction) {
        reaction = r
        reactionAt = Date()
    }

    /// Mean of the visualizer bars, or a gentle 120 bpm pulse without capture.
    func level(at t: Double) -> Double {
        let capture = AudioCaptureManager.shared
        if capture.isCapturing, let bars = capture.latestLevelsSnapshot(), !bars.isEmpty {
            return Double(bars.reduce(0, +)) / Double(bars.count)
        }
        return 0.35 + 0.35 * max(0, sin(t * 2 * .pi * 2))
    }
}

/// Animates while it is in a visible window; `mood` is re-read every frame so
/// time-based transitions (idle → sleep) need no extra plumbing.
/// Hover: looks at the cursor. Click: a poke, plus play/pause when a player is
/// around; double-click skips the track.
final class MascotLayerView: NSView {
    var look = MascotLook(id: "") { didSet { if look != oldValue { palette = MascotImage.palette(look) } } }
    var mood: @MainActor () -> MascotMood = { .idle }
    var activity: @MainActor () -> MascotActivity = { .type }
    var badge: @MainActor () -> Int = { 0 }

    private lazy var palette = MascotImage.palette(look)
    private var timer: Timer?
    private var level = 0.0                     // fast attack, slow release
    private var pokedAt = Date.distantPast
    private var gaze: Int?
    private var pendingToggle: DispatchWorkItem?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: -40, dy: -10),
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        gaze = x < bounds.width * 0.3 ? -1 : (x > bounds.width * 0.7 ? 1 : 0)
    }

    override func mouseExited(with event: NSEvent) { gaze = nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pokedAt = Date()
        let music = MusicManager.shared
        guard Defaults[.devMascotMusicControls], !music.isPlayerIdle else { return }
        pendingToggle?.cancel()
        if event.clickCount >= 2 {
            pendingToggle = nil
            music.nextTrack()
            return
        }
        let toggle = DispatchWorkItem { MainActor.assumeIsolated { MusicManager.shared.togglePlay() } }
        pendingToggle = toggle
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: toggle)
    }

    private func tick() {
        guard let window, window.occlusionState.contains(.visible) else { return }
        let now = Date()
        let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
        let cue = MascotMusicCue.shared
        let musicOn = Defaults[.devMascotMusic]
        var m = MascotMusic(listening: musicOn && MusicManager.shared.isPlaying, gaze: gaze)
        if m.listening {
            let target = cue.level(at: t)
            level = target > level ? target : level * 0.85 + target * 0.15
            m.level = level
        }
        let pokeAge = now.timeIntervalSince(pokedAt)
        if pokeAge < MascotMusic.reactionLength {
            m.reaction = .poke; m.age = pokeAge
        } else if musicOn, let r = cue.reaction {
            m.reaction = r; m.age = now.timeIntervalSince(cue.reactionAt)
        }
        let frame = MascotScene.render(mood(), kind: look.kind, t: t, seed: look.seed, music: m,
                                       activity: activity(), badge: badge())
        layer?.contents = MascotImage.make(frame, palette: palette)
    }
}

struct MascotView: NSViewRepresentable {
    let look: MascotLook
    let mood: @MainActor () -> MascotMood
    var activity: @MainActor () -> MascotActivity = { .type }
    var badge: @MainActor () -> Int = { 0 }

    func makeNSView(context: Context) -> MascotLayerView { MascotLayerView(frame: .zero) }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        view.look = look
        view.mood = mood
        view.activity = activity
        view.badge = badge
    }
}
