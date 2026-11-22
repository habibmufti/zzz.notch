//
//  AnimatedFace.swift
//  zzz.notch
//
//  Living Mac Companion Face rendered in a dropped chin below the camera.
//  3-layer event-driven architecture (zero background polling, zero motion-sickness wobble):
//    - Layer 1 (Base): Dev agents (3-phase organic scribble + quill nib), On-Call
//      (CoreAudio mic / CoreMediaIO camera with breathing dot + sleep lock),
//      Calendar meetings, System health (thermal, memory pressure, battery),
//      Genre-adaptive Music (asymmetric 30ms/220ms FFT envelope + ambient RMS glow
//      + vocal humming wave / mini EQ mouth), and Idle → Sleepy → Sleep.
//    - Layer 2 (Spatial Override): Drag-to-Shelf live file tracking + magnetic
//      eye widening, plus Idle cursor proximity tracking with 1.5s stillness auto-reset.
//    - Layer 3 (One-Shot Reactions): 1.2s choreographed Wake/Unlock greeting,
//      AirPods/Bluetooth connect (starry glints + sparkles), Wi-Fi drop/restore
//      (1.5s NWPathMonitor debounce), Volume Mute & Vol 100% (1.0s cooldown),
//      Charger plugged in, Agent fail, Notification glance, and Poke.
//

import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Defaults
import IOKit.ps
import Network
import SwiftUI

// MARK: - Moods, Reactions & Audio DSP Models

enum AgentFaceMood: String, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case waiting
    case done
    case listening
    case meeting
    case onCallCam
    case onCallMic
    case overheated
    case strained
    case lowBattery
    case sleepy
    case sleep

    static let sleepyAfterSeconds: TimeInterval = 20
    static let sleepAfterSeconds: TimeInterval = 45

    var isOnCall: Bool {
        self == .onCallCam || self == .onCallMic
    }

    var isUrgentInFullscreen: Bool {
        switch self {
        case .waiting, .meeting, .overheated, .lowBattery:
            return true
        default:
            return false
        }
    }

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

enum AgentFaceReaction: Equatable, Sendable {
    case wake
    case airpods
    case wifiLost
    case wifiRestored
    case mute
    case vol100
    case failed
    case charged
    case curious
    case poke
    case trackChange
    case trackSkip

    var duration: TimeInterval {
        switch self {
        case .wake: 1.2
        case .airpods: 2.0
        case .wifiLost: 2.4
        case .wifiRestored: 1.8
        case .mute: 1.8
        case .vol100: 1.1
        case .failed: 3.0
        case .charged: 2.2
        case .curious: 1.8
        case .poke: 1.4
        case .trackChange: 1.5
        case .trackSkip: 1.2
        }
    }
}

enum MusicVibe: String, CaseIterable, Equatable, Sendable {
    case chill
    case groove
    case hype
    case rock
    case melancholy
}

/// Asymmetric envelope follower: Fast Attack (30ms) + Slow Release (220ms).
struct AsymmetricAudioEnvelope: Equatable, Sendable {
    var envBass: Double = 0
    var envMid: Double = 0
    var envHigh: Double = 0
    var envRms: Double = 0

    mutating func update(rawBass: Double, rawMid: Double, rawHigh: Double, dt: Double) {
        let clampedDT = min(max(dt, 0.001), 0.1)
        envBass = Self.follow(cur: envBass, target: rawBass, dt: clampedDT)
        envMid = Self.follow(cur: envMid, target: rawMid, dt: clampedDT)
        envHigh = Self.follow(cur: envHigh, target: rawHigh, dt: clampedDT)
        envRms = envBass * 0.45 + envMid * 0.40 + envHigh * 0.15
    }

    static func follow(cur: Double, target: Double, dt: Double) -> Double {
        let tau = target > cur ? 0.03 : 0.22
        let alpha = 1.0 - exp(-dt / tau)
        return cur + (target - cur) * alpha
    }
}

struct MusicAudioMetrics: Equatable, Sendable {
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    var overall: Double = 0
    var bassPunch: Double = 0
    var bands: [Double] = [0, 0, 0, 0, 0, 0]

    static let silent = MusicAudioMetrics()

    static func from(bars: [Float], previousBass: Double) -> MusicAudioMetrics {
        guard bars.count >= 6 else {
            let avg = bars.isEmpty ? 0 : Double(bars.reduce(0, +)) / Double(bars.count)
            let padded = (0..<6).map { idx in idx < bars.count ? Double(bars[idx]) : avg }
            return MusicAudioMetrics(bass: avg, mid: avg, treble: avg, overall: avg, bassPunch: 0, bands: padded)
        }
        let dBars = bars.prefix(6).map { min(max(Double($0), 0), 1) }
        let bass = (dBars[0] + dBars[1]) * 0.5
        let mid = (dBars[2] + dBars[3]) * 0.5
        let treble = (dBars[4] + dBars[5]) * 0.5
        let overall = (bass + mid + treble) / 3.0
        let punch = min(1, max(0, (bass - previousBass) * 3.8))
        return MusicAudioMetrics(
            bass: bass,
            mid: mid,
            treble: treble,
            overall: overall,
            bassPunch: punch,
            bands: dBars
        )
    }

    func inferredVibe() -> MusicVibe {
        if bass >= 0.52 && overall >= 0.45 {
            return .hype
        }
        if treble >= 0.44 && overall >= 0.44 {
            return .rock
        }
        if overall > 0 && overall <= 0.24 {
            return .chill
        }
        return .groove
    }
}

enum MusicVibeClassifier {
    private static let rockKeywords = [
        "rock", "metal", "punk", "grunge", "hardcore", "metalcore",
        "alternative", "screamo", "thrash", "shoegaze", "emo", "post-punk"
    ]
    private static let hypeKeywords = [
        "electronic", "dance", "edm", "house", "techno", "trance", "dubstep",
        "drum & bass", "dnb", "hip-hop", "hip hop", "rap", "trap", "phonk",
        "club", "hardstyle", "bass", "remix", "drill", "hyperpop", "breakbeat"
    ]
    private static let chillKeywords = [
        "lo-fi", "lofi", "jazz", "classical", "ambient", "chill", "study",
        "acoustic", "new age", "easy listening", "bossa", "instrumental",
        "downtempo", "lounge", "meditation", "piano", "sleep", "focus", "cafe"
    ]
    private static let melancholyKeywords = [
        "ballad", "sad", "galau", "blues", "slowcore", "melanchol",
        "heartbreak", "lullaby", "singer/songwriter", "folk", "soundtrack", "score"
    ]
    private static let grooveKeywords = [
        "pop", "r&b", "soul", "funk", "disco", "k-pop", "j-pop", "indie",
        "reggae", "afrobeat", "latin", "city pop", "synthpop", "dance-pop"
    ]

    static func classify(
        genre: String?,
        title: String = "",
        artist: String = "",
        album: String = ""
    ) -> MusicVibe? {
        if let genre, !genre.isEmpty, let match = matchText(genre.lowercased()) {
            return match
        }
        let combined = "\(title) \(album) \(artist)".lowercased()
        if !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return matchText(combined)
        }
        return nil
    }

    private static func matchText(_ text: String) -> MusicVibe? {
        if chillKeywords.contains(where: { text.contains($0) }) { return .chill }
        if melancholyKeywords.contains(where: { text.contains($0) }) { return .melancholy }
        if rockKeywords.contains(where: { text.contains($0) }) { return .rock }
        if hypeKeywords.contains(where: { text.contains($0) }) { return .hype }
        if grooveKeywords.contains(where: { text.contains($0) }) { return .groove }
        return nil
    }
}

struct UpcomingMeetingCue: Equatable, Sendable {
    let title: String
    let minutesUntilStart: Int
    let joinURL: URL?

    var badgeText: String {
        minutesUntilStart <= 0 ? "NOW" : "\(minutesUntilStart)m"
    }
}

/// Layer 2 Spatial Override state for Drag-to-Shelf tracking.
struct FaceDragState: Equatable, Sendable {
    var active: Bool = false
    /// Normalized offset relative to notch center (-1...1).
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    /// 0 far … 1 right on top of the notch (drives +14% magnetic anticipation).
    var proximity: CGFloat = 0

    static let inactive = FaceDragState()

    static func from(globalPoint: CGPoint, notchCenter: CGPoint, maxRadius: CGFloat = 320) -> FaceDragState {
        let dx = globalPoint.x - notchCenter.x
        // macOS screen Y increases upward; SwiftUI canvas Y increases downward.
        let dy = notchCenter.y - globalPoint.y
        let dist = hypot(dx, dy)
        let proximity = max(0, min(1, 1 - dist / maxRadius))
        let nx = max(-1, min(1, dx / 220))
        let ny = max(-0.4, min(1, dy / 220))
        return FaceDragState(active: true, offsetX: nx, offsetY: ny, proximity: proximity)
    }
}

/// Pure snapshot of all module inputs used to resolve Layer 1 base mood.
struct MacFaceInputs: Equatable, Sendable {
    let devItems: [SystemNotification]
    let celebratingUntil: [String: Date]
    let isMusicPlaying: Bool
    let reactToMusic: Bool
    let upcomingMeeting: UpcomingMeetingCue?
    let reactToCalendar: Bool
    let isCameraActive: Bool
    let isMicActive: Bool
    let thermalState: SystemThermalState
    let isMemoryPressured: Bool
    let batteryPercentage: Int?
    let isCharging: Bool
    let isPluggedIn: Bool
    let reactToSystem: Bool
    let lastActivityAt: Date
    let now: Date

    init(
        devItems: [SystemNotification],
        celebratingUntil: [String: Date],
        isMusicPlaying: Bool,
        reactToMusic: Bool,
        upcomingMeeting: UpcomingMeetingCue?,
        reactToCalendar: Bool,
        isCameraActive: Bool = false,
        isMicActive: Bool = false,
        thermalState: SystemThermalState,
        isMemoryPressured: Bool,
        batteryPercentage: Int?,
        isCharging: Bool,
        isPluggedIn: Bool,
        reactToSystem: Bool,
        lastActivityAt: Date,
        now: Date
    ) {
        self.devItems = devItems
        self.celebratingUntil = celebratingUntil
        self.isMusicPlaying = isMusicPlaying
        self.reactToMusic = reactToMusic
        self.upcomingMeeting = upcomingMeeting
        self.reactToCalendar = reactToCalendar
        self.isCameraActive = isCameraActive
        self.isMicActive = isMicActive
        self.thermalState = thermalState
        self.isMemoryPressured = isMemoryPressured
        self.batteryPercentage = batteryPercentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.reactToSystem = reactToSystem
        self.lastActivityAt = lastActivityAt
        self.now = now
    }

    var isLowBattery: Bool {
        guard let pct = batteryPercentage else { return false }
        return pct <= 15 && !isCharging && !isPluggedIn
    }

    /// Resolves Layer 1 Base Mood in strict priority order:
    /// Agent waiting > Imminent meeting > System critical (thermal/memory/battery)
    /// > Agent working > Agent celebrating > On-Call (Cam/Mic, locks out sleep)
    /// > Music listening > Idle → Sleepy → Sleep.
    func resolveMood() -> AgentFaceMood {
        if devItems.contains(where: { $0.status == .wait }) {
            return .waiting
        }
        if reactToCalendar, upcomingMeeting != nil {
            return .meeting
        }
        if reactToSystem {
            if thermalState == .serious || thermalState == .critical {
                return .overheated
            }
            if isMemoryPressured {
                return .strained
            }
            if isLowBattery {
                return .lowBattery
            }
        }
        if devItems.contains(where: { $0.status == .run }) {
            return .working
        }
        if devItems.contains(where: { item in
            if let until = celebratingUntil[item.id], until > now { return true }
            return item.status == .ok
        }) {
            return .done
        }
        if reactToSystem {
            if isCameraActive { return .onCallCam }
            if isMicActive { return .onCallMic }
        }
        if reactToMusic, isMusicPlaying {
            return .listening
        }

        let latestDev = devItems.map(\.receivedAt).max() ?? .distantPast
        let reference = max(lastActivityAt, latestDev)
        let elapsed = max(0, now.timeIntervalSince(reference))
        return AgentFaceMood.idleMood(elapsedSeconds: elapsed)
    }

    static func upcomingMeeting(
        from events: [EventModel],
        now: Date = Date(),
        leadMinutes: Int = 5
    ) -> UpcomingMeetingCue? {
        let windowStart = now.addingTimeInterval(-60)
        let windowEnd = now.addingTimeInterval(TimeInterval(leadMinutes * 60))

        let candidate = events
            .filter { event in
                guard !event.isAllDay else { return false }
                guard case .event(let attendance) = event.type, attendance != .declined else {
                    return false
                }
                return event.start >= windowStart && event.start <= windowEnd && event.end > now
            }
            .sorted { $0.start < $1.start }
            .first

        guard let candidate else { return nil }
        let seconds = candidate.start.timeIntervalSince(now)
        let mins = seconds <= 0 ? 0 : Int(ceil(seconds / 60))
        return UpcomingMeetingCue(
            title: candidate.title,
            minutesUntilStart: mins,
            joinURL: candidate.meetingLink?.url ?? candidate.calendarAppURL()
        )
    }
}

// MARK: - Event-Driven Signal Observer (Zero Background Polling)

@MainActor
final class MacFaceObserver: ObservableObject {
    static let shared = MacFaceObserver()

    @Published private(set) var thermalState: SystemThermalState
    @Published private(set) var isMemoryPressured = false
    @Published private(set) var batteryPercentage: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var isMicActive = false
    @Published private(set) var isCameraActive = false
    @Published private(set) var isWifiOnline = true
    @Published private(set) var isAudioMuted = false
    @Published private(set) var dragState: FaceDragState = .inactive
    @Published private(set) var lastActivityAt = Date()
    @Published private(set) var detectedTrackGenre: String?
    @Published private(set) var musicVibeFromMetadata: MusicVibe?

    private(set) var lastTypingAt = Date.distantPast
    private(set) var lastAppSwitchAt = Date.distantPast
    private(set) var appSwitchGlanceX: CGFloat = 0

    private(set) var activeReaction: AgentFaceReaction?
    private(set) var reactionAt = Date.distantPast
    /// Incremented whenever a sparkle-worthy event fires so the renderer spawns a burst once.
    private(set) var sparkleEventNonce: Int = 0
    private(set) var lastSparkleColor: (r: Double, g: Double, b: Double) = (0.78, 0.82, 1.0)

    private var thermalObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?
    private var globalInputMonitor: Any?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var powerRunLoopSource: CFRunLoopSource?
    private var pathMonitor: NWPathMonitor?
    private var wifiDebounceTask: Task<Void, Never>?
    private var audioOutputListener: AudioObjectPropertyListenerBlock?
    private var micListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyListenerBlock)] = []
    private let hardwareQueue = DispatchQueue(label: "com.zzznotch.face.hardware", qos: .utility)

    private var cancellables = Set<AnyCancellable>()
    private var lastNotificationID: String?
    private var lastOutputDeviceID: AudioDeviceID = 0
    private var vol100CooldownUntil = Date.distantPast
    private var didSeeInitialVolume = false
    private var genreLookupTask: Task<Void, Never>?
    private var genreCache: [String: String] = [:]
    private var envelope = AsymmetricAudioEnvelope()
    private var lastEnvelopeTime: Double?
    private var smoothedBass: Double = 0
    private var rollingEnergy: Double = 0

    var currentAudioEnvelope: AsymmetricAudioEnvelope { envelope }

    private init() {
        self.thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        refreshBatteryState(fireChargeReaction: false)
        installSystemObservers()
        installNetworkObserver()
        installHardwareAudioCameraObservers()
        installAppObservers()
        installUserActivityObservers()
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        if let appActivateObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver) }
        if let screenUnlockObserver { DistributedNotificationCenter.default().removeObserver(screenUnlockObserver) }
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        memoryPressureSource?.cancel()
        pathMonitor?.cancel()
        wifiDebounceTask?.cancel()
        if let powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerRunLoopSource, .commonModes)
        }
    }

    func noteActivity() {
        let now = Date()
        if now.timeIntervalSince(lastActivityAt) > 0.35 {
            lastActivityAt = now
        }
    }

    func updateDrag(globalPoint: CGPoint, notchCenter: CGPoint) {
        dragState = FaceDragState.from(globalPoint: globalPoint, notchCenter: notchCenter)
        lastActivityAt = Date()
    }

    func noteShelfDropAnticipation() {
        emitSparkles(r: 0.22, g: 0.74, b: 0.97)
    }

    func endDrag() {
        if dragState.active {
            dragState = .inactive
            lastActivityAt = Date()
        }
    }

    func emitSparkles(r: Double, g: Double, b: Double) {
        lastSparkleColor = (r, g, b)
        sparkleEventNonce &+= 1
    }

    func triggerReaction(_ reaction: AgentFaceReaction) {
        activeReaction = reaction
        reactionAt = Date()
        lastActivityAt = Date()

        switch reaction {
        case .airpods:
            emitSparkles(r: 0.22, g: 0.74, b: 0.97)
        case .wifiRestored:
            emitSparkles(r: 0.20, g: 0.83, b: 0.60)
        case .charged:
            emitSparkles(r: 0.36, g: 0.96, b: 0.56)
        default:
            break
        }
    }

    func currentReaction(at now: Date) -> (reaction: AgentFaceReaction, age: TimeInterval)? {
        guard let activeReaction else { return nil }
        let age = now.timeIntervalSince(reactionAt)
        guard age >= 0, age < activeReaction.duration else { return nil }
        return (activeReaction, age)
    }

    func isUserActivelyTyping(at now: Date) -> Bool {
        now.timeIntervalSince(lastTypingAt) < 1.8
    }

    func appSwitchLookX(at now: Date) -> CGFloat? {
        guard now.timeIntervalSince(lastAppSwitchAt) < 1.4 else { return nil }
        return appSwitchGlanceX
    }

    func hasUrgentSignal(now: Date = Date()) -> Bool {
        let store = DevActivityStore.shared
        if store.items.contains(where: { $0.status == .wait }) { return true }
        if Defaults[.faceReactCalendar],
           MacFaceInputs.upcomingMeeting(from: CalendarManager.shared.events, now: now) != nil {
            return true
        }
        if Defaults[.faceReactSystem] {
            if thermalState == .serious || thermalState == .critical { return true }
            if let pct = batteryPercentage, pct <= 15, !isCharging, !isPluggedIn { return true }
        }
        return false
    }

    // MARK: - Layer 3 & Layer 1 System Observers

    private func installSystemObservers() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let next = SystemThermalState(ProcessInfo.processInfo.thermalState)
                if next != self.thermalState {
                    self.thermalState = next
                    self.lastActivityAt = Date()
                }
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let pressured = event.contains(.warning) || event.contains(.critical)
            if pressured != self.isMemoryPressured {
                self.isMemoryPressured = pressured
                self.lastActivityAt = Date()
            }
        }
        source.resume()
        memoryPressureSource = source

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let runLoopSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let observer = Unmanaged<MacFaceObserver>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                observer.refreshBatteryState(fireChargeReaction: true)
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            powerRunLoopSource = runLoopSource
        }

        // Wake / Screen Wake / Screen Unlock -> 1.2s choreographed wake-up greeting!
        let wsCenter = NSWorkspace.shared.notificationCenter
        wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard Defaults[.faceReactSystem] else { return }
                self?.triggerReaction(.wake)
            }
        }
        screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard Defaults[.faceReactSystem] else { return }
                self?.triggerReaction(.wake)
            }
        }
        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard Defaults[.faceReactSystem] else { return }
                self?.triggerReaction(.wake)
            }
        }
    }

    private func installNetworkObserver() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !online {
                    guard self.isWifiOnline, self.wifiDebounceTask == nil else { return }
                    // 1.5s debounce prevents brief Wi-Fi roam flickers from triggering reactions.
                    self.wifiDebounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard !Task.isCancelled, let self else { return }
                        self.wifiDebounceTask = nil
                        self.isWifiOnline = false
                        if Defaults[.faceReactSystem] {
                            self.triggerReaction(.wifiLost)
                        }
                    }
                } else {
                    self.wifiDebounceTask?.cancel()
                    self.wifiDebounceTask = nil
                    if !self.isWifiOnline {
                        self.isWifiOnline = true
                        if Defaults[.faceReactSystem] {
                            self.triggerReaction(.wifiRestored)
                        }
                    }
                }
            }
        }
        monitor.start(queue: hardwareQueue)
        pathMonitor = monitor
    }

    private func installHardwareAudioCameraObservers() {
        hardwareQueue.async { [weak self] in
            guard let self else { return }
            let initialOutput = Self.readDefaultOutputDeviceID()
            let micActive = Self.isAnyAudioInputRunning()
            let camActive = Self.isAnyCameraRunning()
            Task { @MainActor in
                self.lastOutputDeviceID = initialOutput
                self.isMicActive = micActive
                self.isCameraActive = camActive
            }
            self.registerDefaultOutputListener()
            self.registerMicListeners()
            self.registerCameraListeners()
        }
    }

    private nonisolated func registerDefaultOutputListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newID = Self.readDefaultOutputDeviceID()
            let isWireless = Self.isWirelessOrHeadphoneDevice(newID)
            Task { @MainActor in
                guard newID != 0, newID != self.lastOutputDeviceID else { return }
                self.lastOutputDeviceID = newID
                if isWireless && Defaults[.faceReactSystem] {
                    self.triggerReaction(.airpods)
                }
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            hardwareQueue,
            block
        )
        Task { @MainActor in
            self.audioOutputListener = block
        }
    }

    private nonisolated func registerMicListeners() {
        let inputIDs = Self.allInputAudioDeviceIDs()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var registered: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
        for id in inputIDs {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                let running = Self.isAnyAudioInputRunning()
                Task { @MainActor in
                    guard let self, self.isMicActive != running else { return }
                    self.isMicActive = running
                    self.lastActivityAt = Date()
                }
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, hardwareQueue, block) == noErr {
                registered.append((id, block))
            }
        }
        Task { @MainActor in
            self.micListeners = registered
        }
    }

    private nonisolated func registerCameraListeners() {
        let camIDs = Self.allCameraDeviceIDs()
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var registered: [(CMIOObjectID, CMIOObjectPropertyListenerBlock)] = []
        for id in camIDs {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                let running = Self.isAnyCameraRunning()
                Task { @MainActor in
                    guard let self, self.isCameraActive != running else { return }
                    self.isCameraActive = running
                    self.lastActivityAt = Date()
                }
            }
            if CMIOObjectAddPropertyListenerBlock(id, &address, hardwareQueue, block) == noErr {
                registered.append((id, block))
            }
        }
        Task { @MainActor in
            self.cameraListeners = registered
        }
    }

    private nonisolated static func readDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private nonisolated static func isWirelessOrHeadphoneDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &tAddr, 0, nil, &tSize, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        var nameRef: CFString?
        var nSize = UInt32(MemoryLayout<CFString?>.size)
        var nAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &nAddr, 0, nil, &nSize, ptr)
        }
        guard status == noErr, let name = (nameRef as String?)?.lowercased() else { return false }
        return name.contains("airpods") || name.contains("headphone") || name.contains("beats") || name.contains("buds")
    }

    private nonisolated static func allInputAudioDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { id in
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &inSize) == noErr && inSize > 0
        }
    }

    private nonisolated static func isAnyAudioInputRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for id in allInputAudioDeviceIDs() {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private nonisolated static func allCameraDeviceIDs() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, dataSize, &used, &ids) == noErr else {
            return []
        }
        return ids
    }

    private nonisolated static func isAnyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        for id in allCameraDeviceIDs() {
            var running: UInt32 = 0
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(
                id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running
            )
            if status == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private func installUserActivityObservers() {
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                self.lastActivityAt = now
                self.lastAppSwitchAt = now
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let hash = (app?.bundleIdentifier ?? "").utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
                self.appSwitchGlanceX = (hash % 2 == 0) ? 0.13 : -0.13
            }
        }

        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            let isKey = event.type == .keyDown
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let now = Date()
                if isKey {
                    self.lastTypingAt = now
                }
                if now.timeIntervalSince(self.lastActivityAt) > 0.5 {
                    self.lastActivityAt = now
                }
            }
        }
    }

    private func installAppObservers() {
        SystemNotificationManager.shared.$activeNotification
            .sink { [weak self] note in
                guard let self, let note, note.id != self.lastNotificationID else { return }
                self.lastNotificationID = note.id
                if note.status == .fail {
                    self.triggerReaction(.failed)
                } else {
                    self.triggerReaction(.curious)
                }
            }
            .store(in: &cancellables)

        DevActivityStore.shared.$items
            .dropFirst()
            .sink { [weak self] _ in
                self?.lastActivityAt = Date()
            }
            .store(in: &cancellables)

        DevActivityStore.shared.$celebratingUntil
            .dropFirst()
            .sink { [weak self] map in
                if !map.isEmpty {
                    self?.emitSparkles(r: 0.65, g: 0.71, b: 0.99)
                }
            }
            .store(in: &cancellables)

        // Volume Mute & Vol 100% (1.0s cooldown) from existing VolumeManager!
        let volume = VolumeManager.shared
        volume.$isMuted
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] muted in
                guard let self else { return }
                self.isAudioMuted = muted
                if muted && Defaults[.faceReactSystem] {
                    self.triggerReaction(.mute)
                }
            }
            .store(in: &cancellables)

        volume.$rawVolume
            .removeDuplicates()
            .sink { [weak self] vol in
                guard let self else { return }
                guard self.didSeeInitialVolume else {
                    self.didSeeInitialVolume = true
                    return
                }
                let now = Date()
                if vol >= 0.99, !self.isAudioMuted, now >= self.vol100CooldownUntil, Defaults[.faceReactSystem] {
                    self.vol100CooldownUntil = now.addingTimeInterval(1.0)
                    self.triggerReaction(.vol100)
                }
            }
            .store(in: &cancellables)

        let music = MusicManager.shared
        music.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] playing in
                self?.lastActivityAt = Date()
                if playing {
                    self?.refreshMusicGenre(
                        title: music.songTitle,
                        artist: music.artistName,
                        album: music.album
                    )
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            music.$songTitle.removeDuplicates(),
            music.$artistName.removeDuplicates(),
            music.$album.removeDuplicates()
        )
        .sink { [weak self] title, artist, album in
            guard let self else { return }
            self.refreshMusicGenre(title: title, artist: artist, album: album)
        }
        .store(in: &cancellables)
    }

    func sampleAudioMetrics(at t: Double, isPlaying: Bool) -> (metrics: MusicAudioMetrics, envelope: AsymmetricAudioEnvelope, vibe: MusicVibe) {
        let dt = lastEnvelopeTime.map { max(0.001, min(0.1, t - $0)) } ?? (1.0 / 30.0)
        lastEnvelopeTime = t

        guard isPlaying && !isAudioMuted else {
            smoothedBass = 0
            rollingEnergy = 0
            envelope.update(rawBass: 0, rawMid: 0, rawHigh: 0, dt: dt)
            return (.silent, envelope, musicVibeFromMetadata ?? .groove)
        }

        let capture = AudioCaptureManager.shared
        let rawMetrics: MusicAudioMetrics
        if capture.isCapturing, let bars = capture.latestLevelsSnapshot(), !bars.isEmpty {
            rawMetrics = MusicAudioMetrics.from(bars: bars, previousBass: smoothedBass)
            smoothedBass = smoothedBass * 0.72 + rawMetrics.bass * 0.28
            rollingEnergy = rollingEnergy == 0
                ? rawMetrics.overall
                : rollingEnergy * 0.94 + rawMetrics.overall * 0.06
        } else {
            let beatSpeed: Double = {
                switch musicVibeFromMetadata {
                case .hype: return 2.35
                case .rock: return 2.5
                case .chill: return 1.1
                case .melancholy: return 0.9
                case .groove, .none: return 1.85
                }
            }()
            let bands: [Double] = (0..<6).map { i in
                let phase = t * 2 * .pi * beatSpeed + Double(i) * 0.75
                return 0.16 + 0.52 * max(0, sin(phase))
            }
            let level = bands.reduce(0, +) / 6.0
            rawMetrics = MusicAudioMetrics(
                bass: (bands[0] + bands[1]) * 0.5,
                mid: (bands[2] + bands[3]) * 0.5,
                treble: (bands[4] + bands[5]) * 0.5,
                overall: level,
                bassPunch: bands[0] > 0.60 ? (bands[0] - 0.60) * 2.4 : 0,
                bands: bands
            )
            rollingEnergy = level
        }

        envelope.update(
            rawBass: rawMetrics.bass,
            rawMid: rawMetrics.mid,
            rawHigh: rawMetrics.treble,
            dt: dt
        )

        let resolvedVibe: MusicVibe
        if let metaVibe = musicVibeFromMetadata {
            resolvedVibe = metaVibe
        } else {
            let energySnapshot = MusicAudioMetrics(
                bass: smoothedBass > 0 ? smoothedBass : rawMetrics.bass,
                mid: rawMetrics.mid,
                treble: rawMetrics.treble,
                overall: rollingEnergy > 0 ? rollingEnergy : rawMetrics.overall,
                bassPunch: rawMetrics.bassPunch,
                bands: rawMetrics.bands
            )
            resolvedVibe = energySnapshot.inferredVibe()
        }

        return (rawMetrics, envelope, resolvedVibe)
    }

    private func refreshMusicGenre(title: String, artist: String, album: String) {
        genreLookupTask?.cancel()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            detectedTrackGenre = nil
            musicVibeFromMetadata = nil
            return
        }

        let localVibe = MusicVibeClassifier.classify(
            genre: nil,
            title: cleanTitle,
            artist: cleanArtist,
            album: album
        )

        let cacheKey = "\(cleanArtist.lowercased())|\(cleanTitle.lowercased())"
        if let cachedGenre = genreCache[cacheKey] {
            detectedTrackGenre = cachedGenre
            musicVibeFromMetadata = MusicVibeClassifier.classify(
                genre: cachedGenre,
                title: cleanTitle,
                artist: cleanArtist,
                album: album
            ) ?? localVibe
            return
        }

        detectedTrackGenre = nil
        musicVibeFromMetadata = localVibe

        guard Defaults[.devMascotMusic] else { return }
        genreLookupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let genre = await Self.fetchITunesPrimaryGenre(title: cleanTitle, artist: cleanArtist)
            guard !Task.isCancelled, let self, let genre else { return }
            if self.genreCache.count >= 128 {
                self.genreCache.removeAll(keepingCapacity: true)
            }
            self.genreCache[cacheKey] = genre
            self.detectedTrackGenre = genre
            self.musicVibeFromMetadata = MusicVibeClassifier.classify(
                genre: genre,
                title: cleanTitle,
                artist: cleanArtist,
                album: album
            ) ?? localVibe
        }
    }

    private nonisolated static func fetchITunesPrimaryGenre(title: String, artist: String) async -> String? {
        let term = artist.isEmpty ? title : "\(artist) \(title)"
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            struct SearchResponse: Decodable {
                struct Track: Decodable { let primaryGenreName: String? }
                let results: [Track]
            }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.results.first?.primaryGenreName
        } catch {
            return nil
        }
    }

    private func refreshBatteryState(fireChargeReaction: Bool) {
        let wasCharging = isCharging
        guard let battery = SystemUsageSampler.readBatteryUsage() else {
            batteryPercentage = nil
            isCharging = false
            isPluggedIn = false
            return
        }
        batteryPercentage = battery.percentage
        isCharging = battery.isCharging
        isPluggedIn = battery.isPluggedIn
        if fireChargeReaction, !wasCharging, battery.isCharging, Defaults[.faceReactSystem] {
            triggerReaction(.charged)
        }
    }
}

// MARK: - Damped Harmonic Spring & Multi-Harmonic Organic Ink Wave

struct FaceSpring: Equatable, Sendable {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var stiffness: CGFloat
    var damping: CGFloat

    init(initial: CGFloat, stiffness: CGFloat = 250, damping: CGFloat = 24) {
        self.value = initial
        self.target = initial
        self.stiffness = stiffness
        self.damping = damping
    }

    mutating func impulse(_ dv: CGFloat) {
        velocity += dv
    }

    @discardableResult
    mutating func update(dt: CGFloat) -> CGFloat {
        let force = (target - value) * stiffness
        let damp = velocity * damping
        velocity += (force - damp) * dt
        value += velocity * dt
        return value
    }

    var isSettled: Bool {
        abs(target - value) < 0.008 && abs(velocity) < 0.02
    }
}

enum OrganicScribble {
    enum Phase: Equatable, Sendable {
        case writing
        case pause
        case returning
    }

    /// 3-harmonic hand-drawn organic wave (exact PoC proportions).
    static func sampleWave(u: Double, seed1: Double, seed2: Double) -> CGFloat {
        let clamped = max(0, min(1, u))
        let env = 0.42 + 0.58 * pow(sin(clamped * .pi), 0.55)
        let w1 = sin(clamped * .pi * 6.2 * seed1) * 2.6
        let w2 = sin(clamped * .pi * 13.4 * seed2 + 1.1) * 1.15
        let w3 = cos(clamped * .pi * 2.9 + seed1 * 1.8) * 0.8
        return CGFloat((w1 + w2 + w3) * env)
    }
}

// MARK: - Discrete Saccade Planner (Steady Holds, Zero Motion Sickness)

enum FaceSaccade {
    static func hash01(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 32
        return Double(x % 10_000) / 10_000.0
    }

    /// Holds completely still for ~3.2–4.0s, then snaps cleanly to a new gaze point via spring.
    static func discreteLook(at t: TimeInterval, mood: AgentFaceMood) -> CGPoint {
        switch mood {
        case .sleep, .sleepy, .lowBattery, .overheated, .strained, .done, .onCallCam, .onCallMic, .working:
            return .zero
        case .waiting:
            let slot = Int(floor(t / 3.2))
            let r = hash01(slot &+ 91)
            if r < 0.74 { return .zero }
            return CGPoint(x: r < 0.87 ? -6.0 : 6.0, y: 0)
        case .meeting:
            let slot = Int(floor(t / 3.0))
            let r = hash01(slot &+ 137)
            return CGPoint(x: r < 0.55 ? 0 : (r < 0.78 ? -8.0 : 8.0), y: -1.5)
        case .listening:
            let slot = Int(floor(t / 3.8))
            let r = hash01(slot &+ 211)
            if r < 0.58 { return .zero }
            if r < 0.79 { return CGPoint(x: 11.0, y: -1.0) }
            return CGPoint(x: -11.0, y: -1.0)
        case .idle:
            let slot = Int(floor(t / 3.8))
            let r = hash01(slot &+ 43)
            if r < 0.54 { return .zero }
            if r < 0.76 { return CGPoint(x: 13.0, y: 0.5) }
            if r < 0.94 { return CGPoint(x: -13.0, y: 0.5) }
            return CGPoint(x: 0, y: 5.0)
        }
    }

    static func isBlinking(at t: TimeInterval, mood: AgentFaceMood) -> Bool {
        guard mood != .sleep && mood != .sleepy else { return false }
        let slotLength: Double = mood.isOnCall ? 5.2 : (mood == .listening ? 4.2 : 3.8)
        let slot = Int(floor(t / slotLength))
        let local = t - Double(slot) * slotLength
        let blinkAt = 0.6 + hash01(slot &+ 17) * (slotLength - 1.2)
        if local >= blinkAt && local <= blinkAt + 0.105 {
            return true
        }
        if hash01(slot &+ 59) < 0.24 {
            let secondAt = blinkAt + 0.21
            if local >= secondAt && local <= secondAt + 0.095 {
                return true
            }
        }
        return false
    }
}

// MARK: - Living Avatar Physics Engine (1:1 PoC Springs + 3-Phase Scribble + Particles)

struct SparkleParticle {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var size: CGFloat
    var life: Double
    var maxLife: Double
    var color: Color
}

struct SleepZParticle {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var life: Double
    var maxLife: Double
}

/// Exact damped harmonic spring engine tuned to the Living Dynamic Notch PoC
/// (`stiffness: 250, damping: 19`) while keeping zero continuous sine-wave wobble.
final class AgentFaceEngine: ObservableObject {
    var gazeX = FaceSpring(initial: 0, stiffness: 250, damping: 19)
    var gazeY = FaceSpring(initial: 0, stiffness: 250, damping: 19)
    var scaleX = FaceSpring(initial: 1, stiffness: 250, damping: 18)
    var scaleY = FaceSpring(initial: 1, stiffness: 250, damping: 18)
    var inwardTilt = FaceSpring(initial: 0, stiffness: 210, damping: 18)
    var eyelidTop = FaceSpring(initial: 0, stiffness: 175, damping: 17)
    var eyelidBottom = FaceSpring(initial: 0, stiffness: 210, damping: 17)
    var blink = FaceSpring(initial: 0, stiffness: 440, damping: 24)
    var mouthAmp = FaceSpring(initial: 0, stiffness: 180, damping: 18)
    var penAlpha = FaceSpring(initial: 0, stiffness: 190, damping: 20)
    var bounceY = FaceSpring(initial: 0, stiffness: 240, damping: 17)
    var eyeSpacing = FaceSpring(initial: 22, stiffness: 210, damping: 19)
    var eyeLiftY = FaceSpring(initial: 0, stiffness: 190, damping: 18)
    var glowIntensity = FaceSpring(initial: 0, stiffness: 120, damping: 16)
    var red = FaceSpring(initial: 0.90, stiffness: 160, damping: 20)
    var green = FaceSpring(initial: 0.91, stiffness: 160, damping: 20)
    var blue = FaceSpring(initial: 1.00, stiffness: 160, damping: 20)

    // 3-Phase Working Scribble state
    var scribbleProg: Double = 0
    var scribblePhase: OrganicScribble.Phase = .writing
    var scribblePhaseTime: Double = 0
    var scribbleReturnT: Double = 0
    var scribbleSeed1: Double = 1.0
    var scribbleSeed2: Double = 1.55

    // Particles
    var sparkles: [SparkleParticle] = []
    var sleepZs: [SleepZParticle] = []
    private var nextSleepZAt: Double = 0.8
    private var lastSparkleNonce: Int = 0
    private var lastReaction: AgentFaceReaction?
    private var lastTimestamp: TimeInterval?
    private var elapsed: Double = 0
    private var lastMood: AgentFaceMood = .idle

    init(initialMood: AgentFaceMood = .idle) {
        self.lastMood = initialMood
        if initialMood == .working {
            penAlpha.value = 1; penAlpha.target = 1
            eyeLiftY.value = -15; eyeLiftY.target = -15
            eyeSpacing.value = 27; eyeSpacing.target = 27
            inwardTilt.value = 0.17; inwardTilt.target = 0.17
        }
    }

    func step(frame: AgentFaceFrameContext, at timestamp: TimeInterval) {
        let rawDT = lastTimestamp.map { timestamp - $0 } ?? 0
        lastTimestamp = timestamp
        // Match PoC's 0.05 max dt clamp so springs never run in slow motion.
        let dt = min(max(rawDT, 0), 0.05)
        elapsed += dt
        let cgDT = CGFloat(dt)

        let mood = frame.mood
        let reaction = frame.reaction?.reaction
        let rAge = frame.reaction?.age ?? 0

        // Crisp discrete one-shot impulses on state transitions (never continuous wobble!)
        if mood == .working && lastMood != .working {
            scribbleProg = 0
            scribblePhase = .writing
            scribblePhaseTime = 0
            scribbleReturnT = 0
            bounceY.impulse(-16)
        }
        if mood == .done && lastMood != .done {
            bounceY.impulse(-38)
            spawnSparkles(count: 12, color: Color(red: 0.65, green: 0.71, blue: 0.99))
        }
        lastMood = mood

        if reaction != lastReaction {
            lastReaction = reaction
            switch reaction {
            case .airpods:
                bounceY.impulse(-42)
            case .wifiRestored:
                bounceY.impulse(-38)
            case .vol100:
                scaleX.impulse(1.2)
                scaleY.impulse(1.4)
                bounceY.impulse(-44)
            case .wake:
                bounceY.impulse(26)
            case .poke:
                bounceY.impulse(-28)
            default:
                break
            }
        }

        if frame.sparkleNonce != lastSparkleNonce {
            lastSparkleNonce = frame.sparkleNonce
            let c = frame.sparkleColor
            spawnSparkles(count: 11, color: Color(red: c.r, green: c.g, blue: c.b))
        }

        // 1. 3-Phase Working Scribble Engine (exact PoC timings & span: 70pt)
        let spanHalf: CGFloat = 35
        var penX: CGFloat = 0
        var penY: CGFloat = 0

        if mood == .working {
            penAlpha.target = 1
            let scribbleDur = 1.32
            let pauseDur = 0.22
            let returnDur = 0.28

            switch scribblePhase {
            case .writing:
                scribblePhaseTime += dt
                let p = min(1.0, scribblePhaseTime / scribbleDur)
                scribbleProg = p
                scribbleReturnT = 0
                if p >= 1.0 {
                    scribblePhase = .pause
                    scribblePhaseTime = 0
                }
            case .pause:
                scribblePhaseTime += dt
                scribbleProg = 1.0
                if scribblePhaseTime >= pauseDur {
                    scribblePhase = .returning
                    scribblePhaseTime = 0
                    // Crisp left carriage-return saccade impulse (exact PoC!)
                    gazeX.impulse(-165)
                    bounceY.impulse(-14)
                }
            case .returning:
                scribblePhaseTime += dt
                let rt = min(1.0, scribblePhaseTime / returnDur)
                scribbleReturnT = rt
                let ease = 1.0 - pow(1.0 - rt, 3.0)
                scribbleProg = 1.0 - ease
                if rt >= 1.0 {
                    scribbleProg = 0
                    scribbleReturnT = 0
                    scribblePhase = .writing
                    scribblePhaseTime = 0
                    let h1 = FaceSaccade.hash01(Int(elapsed * 100) &+ 13)
                    let h2 = FaceSaccade.hash01(Int(elapsed * 100) &+ 71)
                    scribbleSeed1 = 0.86 + h1 * 0.34
                    scribbleSeed2 = 1.15 + h2 * 0.65
                    bounceY.impulse(12)
                }
            }

            penX = -spanHalf + CGFloat(scribbleProg) * (spanHalf * 2)
            penY = OrganicScribble.sampleWave(u: scribbleProg, seed1: scribbleSeed1, seed2: scribbleSeed2)
        } else {
            penAlpha.target = 0
        }

        // 2. Sleep 'z' particles (calm upward drift, eyes stay 100% still)
        if mood == .sleep {
            if elapsed >= nextSleepZAt {
                let jitter = FaceSaccade.hash01(Int(elapsed * 10) &+ 29)
                sleepZs.append(
                    SleepZParticle(
                        x: 24 + CGFloat(jitter) * 10,
                        y: -8,
                        vx: 7.0 + CGFloat(jitter) * 5.0,
                        vy: -15.0 - CGFloat(jitter) * 6.0,
                        life: 0,
                        maxLife: 1.85
                    )
                )
                nextSleepZAt = elapsed + 0.95
            }
        }
        for i in stride(from: sleepZs.count - 1, through: 0, by: -1) {
            sleepZs[i].life += dt
            sleepZs[i].x += sleepZs[i].vx * cgDT
            sleepZs[i].y += sleepZs[i].vy * cgDT
            if sleepZs[i].life >= sleepZs[i].maxLife {
                sleepZs.remove(at: i)
            }
        }

        // 3. Sparkle particles
        for i in stride(from: sparkles.count - 1, through: 0, by: -1) {
            sparkles[i].life += dt
            sparkles[i].x += sparkles[i].vx * cgDT
            sparkles[i].y += sparkles[i].vy * cgDT
            sparkles[i].vy += 45 * cgDT
            if sparkles[i].life >= sparkles[i].maxLife {
                sparkles.remove(at: i)
            }
        }

        // 4. Layer 1 Base Targets (exact PoC geometry, ZERO continuous sine wobble!)
        let grooveMult: Double = {
            if frame.isMuted { return 0 }
            if mood.isOnCall { return 0.2 }
            if mood == .sleep { return 0.1 }
            if mood == .sleepy { return 0.25 }
            if mood == .working { return 0.45 }
            return 1.0
        }()

        var tGazeX: CGFloat = 0
        var tGazeY: CGFloat = 0
        var tScaleX: CGFloat = 1.0
        var tScaleY: CGFloat = 1.0
        var tInward: CGFloat = 0
        var tTopLid: CGFloat = 0
        var tBotLid: CGFloat = 0
        var tBounceY: CGFloat = 0
        var tEyeSpacing: CGFloat = 22
        var tEyeLiftY: CGFloat = 0
        var tR: Double = 0.902, tG: Double = 0.910, tB: Double = 1.000 // #e6e8ff

        let isPlayingUnmuted = frame.musicListening && !frame.isMuted
        let env = frame.audioEnvelope

        let showHummingMouth = isPlayingUnmuted
            && mood == .listening
            && reaction == nil
            && (frame.musicVibe == .groove || frame.musicVibe == .chill || frame.musicVibe == .melancholy)
        mouthAmp.target = showHummingMouth
            ? CGFloat(0.28 + env.envMid * 1.2 * grooveMult)
            : 0
        glowIntensity.target = isPlayingUnmuted
            ? CGFloat(0.26 + env.envRms * 0.85 * grooveMult)
            : 0

        switch mood {
        case .working:
            tEyeSpacing = 27
            tEyeLiftY = -15
            let trackX = scribblePhase == .returning ? -spanHalf * 0.45 : penX * 0.46
            tGazeX = trackX
            tGazeY = 5.5 + (scribblePhase == .writing ? penY * 0.42 : -1.2)
            tInward = 0.17
            tTopLid = 0.08
            tScaleX = 0.96
            tScaleY = 0.95

        case .idle:
            if let gaze = frame.gaze {
                tGazeX = gaze.x * 14.0
                tGazeY = gaze.y * 7.5
            } else if let switchX = frame.appSwitchLookX {
                tGazeX = switchX * 80
            } else if frame.isUserTyping {
                tGazeX = 3.5
                tGazeY = 4.5
            } else {
                let sac = FaceSaccade.discreteLook(at: timestamp, mood: .idle)
                tGazeX = sac.x
                tGazeY = sac.y
            }

        case .done:
            tScaleX = 1.06
            tScaleY = 0.94
            tBotLid = 0.62 // Pixar happy ^ ^ cheek-squint arch!
            tBounceY = -2
            tR = 0.902; tG = 0.910; tB = 1.000

        case .waiting:
            let sac = FaceSaccade.discreteLook(at: timestamp, mood: .waiting)
            tGazeX = sac.x
            tGazeY = -2.5
            tScaleX = 1.04
            tScaleY = 1.12
            tR = 1.00; tG = 0.86; tB = 0.22

        case .meeting:
            let sac = FaceSaccade.discreteLook(at: timestamp, mood: .meeting)
            tGazeX = sac.x
            tGazeY = -3.0
            tScaleX = 1.02
            tScaleY = 1.06
            tR = 0.42; tG = 0.88; tB = 1.00

        case .onCallCam, .onCallMic:
            tScaleX = 0.98
            tScaleY = 0.98
            tTopLid = 0.06
            tBotLid = 0.08
            tR = 0.902; tG = 0.910; tB = 1.000

        case .listening:
            let sac = FaceSaccade.discreteLook(at: timestamp, mood: .listening)
            tGazeX = frame.gaze.map { $0.x * 14.0 } ?? sac.x
            tGazeY = frame.gaze.map { $0.y * 6.5 } ?? sac.y
            tEyeLiftY = -7.0

            switch frame.musicVibe {
            case .chill:
                tTopLid = min(0.42, 0.22 + CGFloat(env.envMid * 0.18))
                tBotLid = 0.16 + CGFloat(env.envMid * 0.16)
                tR = 0.902; tG = 0.910; tB = 1.000
            case .melancholy:
                tInward = -0.13
                tTopLid = min(0.42, 0.22 + CGFloat(env.envMid * 0.16))
                tBotLid = 0.14 + CGFloat(env.envMid * 0.12)
                tR = 0.78; tG = 0.84; tB = 1.00
            case .groove:
                tTopLid = CGFloat(env.envMid * 0.06)
                tBotLid = 0.14 + CGFloat(env.envMid * 0.16)
                tR = 0.902; tG = 0.910; tB = 1.000
            case .hype:
                tInward = 0.08
                tScaleX = 1.03
                tScaleY = 1.05
                tR = 0.94; tG = 0.82; tB = 1.00
            case .rock:
                tInward = 0.20
                tTopLid = 0.18
                tScaleX = 1.04
                tR = 1.00; tG = 0.72; tB = 0.68
            }

        case .overheated:
            tInward = -0.12
            tTopLid = 0.26
            tScaleY = 0.84
            tR = 1.00; tG = 0.56; tB = 0.30

        case .strained:
            tInward = 0.14
            tTopLid = 0.36
            tBotLid = 0.22
            tScaleX = 1.06
            tScaleY = 0.72
            tR = 1.00; tG = 0.78; tB = 0.30

        case .lowBattery:
            tInward = -0.10
            tTopLid = 0.42
            tScaleY = 0.74
            tR = 0.96; tG = 0.44; tB = 0.44

        case .sleepy:
            // Clean chunky horizontal bars (never erased by eyelids).
            tGazeY = 3.0
            tTopLid = 0
            tBotLid = 0
            tScaleX = 1.16
            tScaleY = 0.24
            tR = 0.86; tG = 0.87; tB = 0.97

        case .sleep:
            // Crisp visible `- -` sleeping bars + drifting 'z' particles.
            tGazeY = 4.5
            tTopLid = 0
            tBotLid = 0
            tScaleX = 1.18
            tScaleY = 0.14
            tR = 0.72; tG = 0.75; tB = 0.89 // #b8bee4
        }

        // 5. Blink Target
        var tBlink: CGFloat = 0
        if reaction == .wake {
            // 1.2s choreographed wake-up: `- -` closed -> stretch -> double-blink greeting -> smile
            if rAge < 0.28 {
                tScaleX = 1.18; tScaleY = 0.14; tTopLid = 0; tBotLid = 0; tBounceY = 3
            } else if rAge < 0.62 {
                tScaleX = 0.92; tScaleY = 1.18; tTopLid = 0; tBotLid = 0; tBounceY = -5
            } else if rAge < 0.92 {
                tBlink = ((rAge > 0.68 && rAge < 0.76) || (rAge > 0.81 && rAge < 0.89)) ? 1 : 0
                tBotLid = 0.22
            } else {
                tBotLid = 0.34
            }
        } else if reaction != .failed && reaction != .poke && mood != .sleep {
            tBlink = FaceSaccade.isBlinking(at: timestamp, mood: mood) ? 1 : 0
        }

        // 6. Layer 3 One-Shot Reaction Overrides
        switch reaction {
        case .airpods:
            tScaleX = 1.12; tScaleY = 1.12; tBotLid = 0.36; tTopLid = 0
        case .wifiLost:
            tScaleX = 0.94; tScaleY = 0.88; tTopLid = 0.22; tInward = -0.14
        case .wifiRestored:
            tScaleX = 1.08; tScaleY = 1.04; tBotLid = 0.56; tTopLid = 0
        case .mute:
            tTopLid = 0.34; tBotLid = 0.14; tScaleY = 0.86
        case .vol100:
            tScaleX = 1.22; tScaleY = 1.24; tTopLid = 0; tBotLid = 0
        case .charged:
            tScaleX = 1.10; tScaleY = 1.12; tBotLid = 0.42; tTopLid = 0
            tR = 0.40; tG = 0.96; tB = 0.62
        case .poke:
            tScaleX = 1.08; tScaleY = 0.95; tBotLid = 0.64; tTopLid = 0
        case .trackSkip:
            tGazeX = 16.0
        case .trackChange:
            tScaleX = 1.06; tScaleY = 1.08; tBotLid = 0.26
        case .failed:
            tR = 1.00; tG = 0.44; tB = 0.44
        case .wake, .curious, .none:
            break
        }

        // 7. Layer 2 Spatial Override — Drag-to-Shelf (highest gaze priority!)
        if frame.drag.active {
            tGazeX = frame.drag.offsetX * 18.0
            tGazeY = frame.drag.offsetY * 11.0
            let boost = 1.0 + frame.drag.proximity * 0.14
            tScaleX *= boost
            tScaleY *= boost
            tTopLid = 0
            tBotLid = 0
            tInward = 0
        }

        // Commit targets & step all springs
        gazeX.target = tGazeX
        gazeY.target = tGazeY
        scaleX.target = tScaleX
        scaleY.target = tScaleY
        inwardTilt.target = tInward
        eyelidTop.target = tTopLid
        eyelidBottom.target = tBotLid
        blink.target = tBlink
        bounceY.target = tBounceY
        eyeSpacing.target = tEyeSpacing
        eyeLiftY.target = tEyeLiftY
        red.target = CGFloat(tR)
        green.target = CGFloat(tG)
        blue.target = CGFloat(tB)

        gazeX.update(dt: cgDT)
        gazeY.update(dt: cgDT)
        scaleX.update(dt: cgDT)
        scaleY.update(dt: cgDT)
        inwardTilt.update(dt: cgDT)
        eyelidTop.update(dt: cgDT)
        eyelidBottom.update(dt: cgDT)
        blink.update(dt: cgDT)
        mouthAmp.update(dt: cgDT)
        penAlpha.update(dt: cgDT)
        bounceY.update(dt: cgDT)
        eyeSpacing.update(dt: cgDT)
        eyeLiftY.update(dt: cgDT)
        glowIntensity.update(dt: cgDT)
        red.update(dt: cgDT)
        green.update(dt: cgDT)
        blue.update(dt: cgDT)
    }

    func spawnSparkles(count: Int, color: Color) {
        for i in 0..<count {
            let frac = Double(i) / Double(max(1, count))
            let h = FaceSaccade.hash01(Int(elapsed * 100) &+ i * 17)
            let ang = frac * .pi * 2 + h * 0.5
            let spd = 28.0 + h * 44.0
            sparkles.append(
                SparkleParticle(
                    x: CGFloat((h - 0.5) * 46),
                    y: CGFloat((FaceSaccade.hash01(i &+ 9) - 0.5) * 18),
                    vx: CGFloat(cos(ang) * spd),
                    vy: CGFloat(sin(ang) * spd - 12),
                    size: CGFloat(2.2 + h * 2.2),
                    life: 0,
                    maxLife: 0.65 + h * 0.35,
                    color: color
                )
            )
        }
    }

    var areSpringsSettled: Bool {
        gazeX.isSettled && gazeY.isSettled && scaleX.isSettled && scaleY.isSettled
            && eyelidTop.isSettled && eyelidBottom.isSettled && inwardTilt.isSettled
            && bounceY.isSettled && blink.isSettled && penAlpha.isSettled && sparkles.isEmpty
    }
}

// MARK: - Cursor Proximity Tracking (1.5s Stillness Auto-Reset)

final class FaceTrackingNSView: NSView {
    var onGazeChanged: ((CGPoint?, Date) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let expanded = bounds.insetBy(dx: -160, dy: -90)
        addTrackingArea(
            NSTrackingArea(
                rect: expanded,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                owner: self
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nx = max(-1, min(1, ((loc.x / bounds.width) - 0.5) * 1.25))
        let ny = max(-1, min(1, (0.5 - (loc.y / bounds.height)) * 1.1))
        onGazeChanged?(CGPoint(x: nx, y: ny), Date())
    }

    override func mouseExited(with event: NSEvent) {
        onGazeChanged?(nil, Date())
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct FaceTrackingOverlay: NSViewRepresentable {
    let enabled: Bool
    let onGazeChanged: (CGPoint?, Date) -> Void

    func makeNSView(context: Context) -> FaceTrackingNSView {
        let view = FaceTrackingNSView(frame: .zero)
        view.onGazeChanged = enabled ? onGazeChanged : nil
        return view
    }

    func updateNSView(_ view: FaceTrackingNSView, context: Context) {
        view.onGazeChanged = enabled ? onGazeChanged : nil
        if !enabled {
            onGazeChanged(nil, Date())
        }
    }
}

// MARK: - Canvas Renderer

struct AgentFaceFrameContext {
    var mood: AgentFaceMood
    var reaction: (reaction: AgentFaceReaction, age: TimeInterval)? = nil
    var drag: FaceDragState = .inactive
    var isMuted: Bool = false
    var musicListening: Bool = false
    var musicVibe: MusicVibe = .groove
    var musicMetrics: MusicAudioMetrics = .silent
    var audioEnvelope: AsymmetricAudioEnvelope = AsymmetricAudioEnvelope()
    var musicTint: (r: Double, g: Double, b: Double)? = nil
    var gaze: CGPoint? = nil
    var isUserTyping: Bool = false
    var appSwitchLookX: CGFloat? = nil
    var sparkleNonce: Int = 0
    var sparkleColor: (r: Double, g: Double, b: Double) = (0.78, 0.82, 1.0)
}

struct AgentFaceCanvas: View {
    let contextProvider: (Date) -> AgentFaceFrameContext
    @StateObject private var engine = AgentFaceEngine()

    init(mood: AgentFaceMood) {
        self.contextProvider = { _ in AgentFaceFrameContext(mood: mood) }
    }

    init(contextProvider: @escaping (Date) -> AgentFaceFrameContext) {
        self.contextProvider = contextProvider
    }

    private func frameInterval(for ctx: AgentFaceFrameContext) -> Double {
        // 60fps during active animations / transitions (matches PoC requestAnimationFrame),
        // dropping to calm 20fps in settled idle & 15fps in sleep.
        if ctx.reaction != nil || ctx.drag.active || ctx.gaze != nil || !engine.areSpringsSettled {
            return 1.0 / 60.0
        }
        switch ctx.mood {
        case .working, .listening, .overheated:
            return 1.0 / 60.0
        case .waiting, .done, .meeting, .onCallCam, .onCallMic, .strained, .idle, .sleepy, .lowBattery:
            return 1.0 / 30.0
        case .sleep:
            return 1.0 / 20.0
        }
    }

    var body: some View {
        let probe = contextProvider(Date())
        TimelineView(.animation(minimumInterval: frameInterval(for: probe))) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let frame = contextProvider(now)
            let _ = engine.step(frame: frame, at: t)

            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                guard w > 0, h > 0 else { return }

                let cx = w / 2
                let eyeCenterY = h * 0.46 + engine.eyeLiftY.value + engine.bounceY.value
                let reaction = frame.reaction?.reaction
                let isPureMusic = frame.mood == .listening && reaction == nil && !frame.isMuted
                let eyeColor = Color(
                    red: Double(min(max(engine.red.value, 0), 1)),
                    green: Double(min(max(engine.green.value, 0), 1)),
                    blue: Double(min(max(engine.blue.value, 0), 1))
                )
                let accentColor: Color = {
                    if let tint = frame.musicTint {
                        return Color(red: tint.r, green: tint.g, blue: tint.b)
                    }
                    return Color(red: 0.88, green: 0.61, blue: 0.42) // PoC warm peach accent
                }()

                // 1. Ambient Radial RMS Glow behind eyes (exact PoC proportions)
                let glow = max(0, Double(engine.glowIntensity.value))
                if glow > 0.02 {
                    let radius = 38 + glow * 34
                    let glowRect = CGRect(
                        x: cx - radius,
                        y: eyeCenterY - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.fill(
                        Path(ellipseIn: glowRect),
                        with: .radialGradient(
                            Gradient(colors: [
                                accentColor.opacity(min(0.42, glow * 0.42)),
                                accentColor.opacity(0)
                            ]),
                            center: CGPoint(x: cx, y: eyeCenterY),
                            startRadius: 4,
                            endRadius: radius
                        )
                    )
                }

                // 2. Left (-1) & Right (+1) Eyes — 1:1 PoC size (19.0 x 32.5) + Bloom + 3D Foreshortening
                let gx = engine.gazeX.value
                let gy = engine.gazeY.value
                let blinkVal = min(max(engine.blink.value, 0), 1)
                let openY = max(0.08, 1.0 - blinkVal * 0.92)
                let baseW: CGFloat = 19.0
                let baseH: CGFloat = 32.5
                let spacing = engine.eyeSpacing.value
                let topLid = max(0, engine.eyelidTop.value)
                let botLid = max(0, engine.eyelidBottom.value)
                let lookRatio = max(-1, min(1, gx / 19.0))
                let shadowColor = (frame.musicListening && !frame.isMuted)
                    ? accentColor.opacity(0.55)
                    : Color(red: 0.89, green: 0.90, blue: 1.0).opacity(0.46)

                for (index, side) in [-1.0, 1.0].enumerated() {
                    let sideF = CGFloat(side)
                    let sphericalSide = sideF * lookRatio
                    let depthScale = 1.0 + sphericalSide * 0.07
                    let widthPersp = 1.0 + sphericalSide * 0.09 - (sphericalSide < 0 ? abs(sphericalSide) * 0.09 : 0)

                    let ex = cx + gx + sideF * spacing * (1.0 - abs(lookRatio) * 0.05)
                    let ey = eyeCenterY + gy
                    let ew = baseW * engine.scaleX.value * widthPersp
                    var eh = max(3.6, baseH * engine.scaleY.value * openY * depthScale)

                    if reaction == .curious {
                        eh *= (index == 0 ? 0.74 : 1.16)
                    }

                    var eyeCtx = ctx
                    eyeCtx.translateBy(x: ex, y: ey)
                    eyeCtx.rotate(by: .radians(Double(sideF * -engine.inwardTilt.value)))

                    if reaction == .failed {
                        var chevron = Path()
                        let hw = ew * 0.48
                        let hh: CGFloat = 10.0
                        if index == 0 {
                            chevron.move(to: CGPoint(x: -hw, y: -hh))
                            chevron.addLine(to: CGPoint(x: hw, y: 0))
                            chevron.addLine(to: CGPoint(x: -hw, y: hh))
                        } else {
                            chevron.move(to: CGPoint(x: hw, y: -hh))
                            chevron.addLine(to: CGPoint(x: -hw, y: 0))
                            chevron.addLine(to: CGPoint(x: hw, y: hh))
                        }
                        eyeCtx.stroke(
                            chevron,
                            with: .color(eyeColor),
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                        )
                        continue
                    }

                    // Pill eye body with lush PoC bloom (shadowBlur 13 -> radius ~8)
                    let pillRect = CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh)
                    let pillPath = Path(roundedRect: pillRect, cornerRadius: min(ew, eh) * 0.48)
                    eyeCtx.drawLayer { layerCtx in
                        layerCtx.addFilter(.shadow(color: shadowColor, radius: 9, x: 0, y: 0))
                        layerCtx.fill(pillPath, with: .color(eyeColor))
                    }

                    // Starry highlight glint during AirPods / Charged connect
                    if reaction == .airpods || reaction == .charged {
                        let glintRect = CGRect(x: -ew * 0.28, y: -eh * 0.30, width: 5.2, height: 5.2)
                        eyeCtx.fill(Path(ellipseIn: glintRect), with: .color(.white))
                    }

                    // Top Eyelid Curtain (Working focus, Rock fierce, Mute)
                    if topLid > 0.02 {
                        var lidCtx = eyeCtx
                        let browAng: Double = (frame.mood == .working || (isPureMusic && frame.musicVibe == .rock))
                            ? 0.17
                            : (frame.mood == .overheated || (isPureMusic && frame.musicVibe == .melancholy) ? -0.15 : -0.08)
                        lidCtx.rotate(by: .radians(Double(sideF) * browAng))
                        let lidRect = CGRect(x: -ew, y: -eh / 2 - 6, width: ew * 2, height: eh * topLid * 1.12 + 6)
                        lidCtx.fill(Path(lidRect), with: .color(.black))
                    }

                    // Bottom Cheek-Squint Arch (Pixar-style happy ^ ^ eyes!)
                    if botLid > 0.03 {
                        let r = ew * 0.88
                        let archY = eh * 0.5 + r * (1.0 - botLid * 0.94)
                        var arch = Path()
                        arch.addArc(
                            center: CGPoint(x: 0, y: archY),
                            radius: r,
                            startAngle: .degrees(180),
                            endAngle: .degrees(0),
                            clockwise: false
                        )
                        arch.addLine(to: CGPoint(x: ew, y: eh + 6))
                        arch.addLine(to: CGPoint(x: -ew, y: eh + 6))
                        arch.closeSubpath()
                        eyeCtx.fill(arch, with: .color(.black))
                    }
                }

                // 3. Working Desk: 1:1 PoC 44pt gap + 70pt span + glowing organic ink + 17.8pt quill nib
                let penA = min(max(Double(engine.penAlpha.value), 0), 1)
                if penA > 0.02 && reaction != .failed {
                    drawOrganicScribbleAndQuill(
                        in: &ctx,
                        cx: cx,
                        deskY: min(h - 10, eyeCenterY + 44),
                        alpha: penA,
                        t: t,
                        color: eyeColor
                    )
                }

                // 4. Music Mouth: Vocal Humming Wave (accent glowing) or 5-Bar Mini EQ (Hype/Rock)
                if isPureMusic && (frame.musicVibe == .hype || frame.musicVibe == .rock) {
                    drawMiniEqualizerMouth(
                        in: &ctx,
                        cx: cx,
                        my: eyeCenterY + 27,
                        bands: frame.musicMetrics.bands,
                        color: accentColor
                    )
                } else {
                    let mAmp = max(0, CGFloat(engine.mouthAmp.value))
                    if mAmp > 0.03 && reaction != .failed {
                        drawVocalHummingMouth(
                            in: &ctx,
                            cx: cx,
                            baseY: eyeCenterY + 27,
                            amp: mAmp,
                            t: t,
                            color: accentColor
                        )
                    }
                }

                // 5. Overheated sweat bead
                if frame.mood == .overheated {
                    let phase = t.truncatingRemainder(dividingBy: 2.0) / 2.0
                    let dropX = cx + spacing + 16
                    let dropY = eyeCenterY - 12 + CGFloat(phase) * 18
                    let alpha = sin(phase * .pi)
                    let drop = CGRect(x: dropX - 2.2, y: dropY - 3.2, width: 4.4, height: 6.4)
                    ctx.fill(
                        Path(ellipseIn: drop),
                        with: .color(Color(red: 0.52, green: 0.86, blue: 1.0).opacity(alpha * 0.9))
                    )
                }

                // 6. Sleep Floating 'z' Particles
                for z in engine.sleepZs {
                    let u = z.life / z.maxLife
                    let alpha = u < 0.2 ? (u / 0.2) : max(0, 1.0 - (u - 0.2) / 0.8)
                    let fontSize = 10.0 + u * 5.0
                    let text = Text("z")
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.65, green: 0.71, blue: 0.99).opacity(alpha * 0.85))
                    ctx.draw(text, at: CGPoint(x: cx + z.x, y: eyeCenterY + z.y))
                }

                // 7. Layer 3 Floating Badges (AirPods / Wi-Fi '?' / Mute)
                if reaction == .airpods || reaction == .wifiLost || reaction == .mute {
                    let bx = cx + 52
                    let by = eyeCenterY - 12
                    let badgeRect = CGRect(x: bx - 11, y: by - 11, width: 22, height: 22)
                    ctx.fill(Path(ellipseIn: badgeRect), with: .color(.white.opacity(0.14)))

                    let symbol: String
                    let tint: Color
                    switch reaction {
                    case .wifiLost:
                        symbol = "?"
                        tint = Color(red: 0.98, green: 0.75, blue: 0.14)
                    case .airpods:
                        symbol = "♪"
                        tint = Color(red: 0.22, green: 0.74, blue: 0.97)
                    default:
                        symbol = "×"
                        tint = Color(red: 0.98, green: 0.44, blue: 0.52)
                    }
                    let label = Text(symbol)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    ctx.draw(label, at: CGPoint(x: bx, y: by))
                }

                // 8. Sparkle Burst Particles
                for sp in engine.sparkles {
                    let u = sp.life / sp.maxLife
                    let alpha = max(0, 1.0 - u)
                    let radius = sp.size * CGFloat(1.0 - u * 0.4)
                    let dot = CGRect(
                        x: cx + sp.x - radius,
                        y: eyeCenterY + sp.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.fill(Path(ellipseIn: dot), with: .color(sp.color.opacity(alpha)))
                }
            }
        }
    }

    private func drawOrganicScribbleAndQuill(
        in ctx: inout GraphicsContext,
        cx: CGFloat,
        deskY: CGFloat,
        alpha: Double,
        t: TimeInterval,
        color: Color
    ) {
        let spanX: CGFloat = 70
        let startX = cx - spanX / 2
        let prog = max(0, min(1, engine.scribbleProg))
        let isReturn = engine.scribblePhase == .returning
        let isPause = engine.scribblePhase == .pause
        let inkFade = isReturn ? max(0, 1.0 - engine.scribbleReturnT * 1.25) : 1.0

        // Organic Multi-Harmonic Ink Trail with soft glow
        if inkFade > 0.02 && (isReturn || prog > 0.01) {
            let samples = 56
            let startFrac = isReturn ? engine.scribbleReturnT * 0.45 : 0.0
            let endFrac = isReturn ? 1.0 : prog
            let minI = Int(floor(Double(samples) * startFrac))
            let maxI = Int(floor(Double(samples) * endFrac))

            if maxI > minI {
                var trail = Path()
                for i in minI...maxI {
                    let u = Double(i) / Double(samples)
                    let px = startX + CGFloat(u) * spanX
                    let py = deskY + OrganicScribble.sampleWave(u: u, seed1: engine.scribbleSeed1, seed2: engine.scribbleSeed2)
                    if i == minI {
                        trail.move(to: CGPoint(x: px, y: py))
                    } else {
                        trail.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                ctx.drawLayer { layerCtx in
                    layerCtx.addFilter(.shadow(color: color.opacity(0.38 * alpha * inkFade), radius: 5, x: 0, y: 0))
                    layerCtx.stroke(
                        trail,
                        with: .color(color.opacity(alpha * 0.92 * inkFade)),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }

        // True Teardrop Quill Pen Nib (17.8pt) with Parabolic Return Arc + Glow
        let tipX = startX + CGFloat(prog) * spanX
        let waveY = OrganicScribble.sampleWave(u: prog, seed1: engine.scribbleSeed1, seed2: engine.scribbleSeed2)
        let liftY: CGFloat = {
            if isPause { return -3.6 }
            if isReturn { return CGFloat(-sin(engine.scribbleReturnT * .pi) * 14.5) }
            return 0
        }()
        let tipY = deskY + (isReturn ? 0 : waveY) + liftY
        let wristJitter: Double = {
            if engine.scribblePhase == .writing {
                return sin(t * 32) * 0.11 + cos(t * 19) * 0.05
            }
            return isReturn ? -0.18 : 0.04
        }()

        var nibCtx = ctx
        nibCtx.translateBy(x: tipX, y: tipY)
        nibCtx.rotate(by: .radians(0.66 + wristJitter))

        var quill = Path()
        quill.move(to: .zero)
        quill.addCurve(
            to: CGPoint(x: 0, y: -17.8),
            control1: CGPoint(x: -5.8, y: -5.5),
            control2: CGPoint(x: -5.4, y: -14.8)
        )
        quill.addCurve(
            to: .zero,
            control1: CGPoint(x: 5.4, y: -14.8),
            control2: CGPoint(x: 5.8, y: -5.5)
        )
        quill.closeSubpath()
        nibCtx.drawLayer { layerCtx in
            layerCtx.addFilter(.shadow(color: color.opacity(0.5 * alpha), radius: 6, x: 0, y: 0))
            layerCtx.fill(quill, with: .color(color.opacity(alpha)))
        }

        var slit = Path()
        slit.move(to: CGPoint(x: 0, y: -1.2))
        slit.addLine(to: CGPoint(x: 0, y: -7.8))
        nibCtx.stroke(
            slit,
            with: .color(Color.black.opacity(0.58 * alpha)),
            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
        )
    }

    private func drawVocalHummingMouth(
        in ctx: inout GraphicsContext,
        cx: CGFloat,
        baseY: CGFloat,
        amp: CGFloat,
        t: TimeInterval,
        color: Color
    ) {
        let halfSpan = 24 + amp * 7
        let waveH = 1.6 + amp * 7.5
        var wave = Path()
        let steps = 36
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let x = cx - halfSpan + CGFloat(u) * halfSpan * 2
            let win = sin(u * .pi)
            let yOff = (sin(u * .pi * 4 - t * 11) * 0.72 + sin(u * .pi * 8 + t * 15) * 0.28) * Double(waveH) * win
            let pt = CGPoint(x: x, y: baseY + CGFloat(yOff))
            if i == 0 { wave.move(to: pt) } else { wave.addLine(to: pt) }
        }
        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.shadow(color: color.opacity(0.72), radius: 7, x: 0, y: 0))
            layerCtx.stroke(
                wave,
                with: .color(color.opacity(min(1, Double(amp) * 1.15))),
                style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawMiniEqualizerMouth(
        in ctx: inout GraphicsContext,
        cx: CGFloat,
        my: CGFloat,
        bands: [Double],
        color: Color
    ) {
        let count = 5
        let barW: CGFloat = 3.0
        let spacing: CGFloat = 5.0
        let totalW = CGFloat(count - 1) * spacing
        let maxH: CGFloat = 13.0

        for i in 0..<count {
            let level = i < bands.count ? bands[i] : 0.2
            let envelope = 1.0 - abs(Double(i) - 2.0) * 0.18
            let h = max(barW, CGFloat(level * envelope) * maxH + barW)
            let x = cx - totalW / 2 + CGFloat(i) * spacing
            let rect = CGRect(x: x - barW / 2, y: my - h / 2, width: barW, height: h)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: barW / 2),
                with: .color(color.opacity(0.92))
            )
        }
    }
}

// MARK: - Dropped Chin Container & Compact Music Wings (1:1 PoC Layout)

struct AgentFaceDroppedChinView: View {
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    let isWorking: Bool
    let showMusicWings: Bool
    let albumArt: NSImage?
    let musicAccent: Color
    let audioEnvelopeProvider: () -> AsymmetricAudioEnvelope
    let meetingBadge: UpcomingMeetingCue?
    let onCallDotColor: Color?
    let trackCursor: Bool
    let onGazeChanged: (CGPoint?, Date) -> Void
    let onMeetingTap: ((UpcomingMeetingCue) -> Void)?
    let contextProvider: (Date) -> AgentFaceFrameContext

    private var faceHeight: CGFloat { isWorking ? 112 : 86 }
    private var totalWidth: CGFloat { max(cameraWidth, showMusicWings ? 268 : 214) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: totalWidth, height: cameraHeight)

            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    if showMusicWings {
                        leftAlbumWing
                            .frame(width: 32)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }

                    AgentFaceCanvas(contextProvider: contextProvider)
                        .frame(width: 204, height: faceHeight)

                    if showMusicWings {
                        rightMiniEQWing
                            .frame(width: 32)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showMusicWings)
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isWorking)

                if let meetingBadge {
                    Button {
                        onMeetingTap?(meetingBadge)
                    } label: {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color(red: 0.44, green: 0.90, blue: 1.0))
                                .frame(width: 4, height: 4)
                            Text(meetingBadge.badgeText)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 5)
                    .help("\(meetingBadge.title) · Click to join")
                }
            }
            .overlay(alignment: .topTrailing) {
                if let onCallDotColor {
                    Circle()
                        .fill(onCallDotColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: onCallDotColor.opacity(0.9), radius: 5)
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                }
            }
            .overlay {
                FaceTrackingOverlay(enabled: trackCursor, onGazeChanged: onGazeChanged)
            }
        }
    }

    private var leftAlbumWing: some View {
        Group {
            if let albumArt {
                Image(nsImage: albumArt)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [musicAccent, musicAccent.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .shadow(color: musicAccent.opacity(0.45), radius: 6)
    }

    private var rightMiniEQWing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let env = audioEnvelopeProvider()
            let vals = [
                env.envBass,
                env.envMid,
                env.envHigh,
                (env.envBass + env.envMid) * 0.55
            ]
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { idx in
                    let h = 3.5 + min(14.5, vals[idx] * 16.5)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(musicAccent)
                        .frame(width: 2.5, height: CGFloat(h))
                }
            }
            .frame(height: 18, alignment: .bottom)
        }
    }
}

/// Unified closed-notch Mac companion face reacting across all 3 layers.
struct DevAgentFaceLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var devStore = DevActivityStore.shared
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var calendar = CalendarManager.shared
    @ObservedObject private var observer = MacFaceObserver.shared
    @Default(.devMascotMusic) private var reactToMusic
    @Default(.faceReactCalendar) private var reactToCalendar
    @Default(.faceReactSystem) private var reactToSystem
    @Default(.faceTrackCursor) private var trackCursor
    @Default(.playerColorTinting) private var playerColorTinting
    let cameraHeight: CGFloat

    @State private var gaze: CGPoint?
    @State private var lastGazeMoveAt = Date.distantPast

    var body: some View {
        let now = Date()
        let meeting = reactToCalendar
            ? MacFaceInputs.upcomingMeeting(from: calendar.events, now: now)
            : nil
        let isWorkingNow = devStore.items.contains(where: { $0.status == .run })
        let showMusicWings = reactToMusic && music.isPlaying && !observer.isAudioMuted
        let musicAccent = resolvedMusicAccentColor()
        let onCallColor: Color? = {
            guard reactToSystem else { return nil }
            if observer.isCameraActive { return Color(red: 0.29, green: 0.87, blue: 0.50) }
            if observer.isMicActive { return Color(red: 0.98, green: 0.57, blue: 0.24) }
            return nil
        }()

        AgentFaceDroppedChinView(
            cameraWidth: vm.closedNotchSize.width,
            cameraHeight: cameraHeight,
            isWorking: isWorkingNow,
            showMusicWings: showMusicWings,
            albumArt: music.albumArt,
            musicAccent: musicAccent,
            audioEnvelopeProvider: { observer.currentAudioEnvelope },
            meetingBadge: meeting,
            onCallDotColor: onCallColor,
            trackCursor: trackCursor,
            onGazeChanged: { point, when in
                gaze = point
                if point != nil {
                    lastGazeMoveAt = when
                    observer.noteActivity()
                }
            },
            onMeetingTap: { cue in
                if let url = cue.joinURL {
                    NSWorkspace.shared.open(url)
                }
            },
            contextProvider: { date in
                let liveMeeting = reactToCalendar
                    ? MacFaceInputs.upcomingMeeting(from: calendar.events, now: date)
                    : nil
                let inputs = MacFaceInputs(
                    devItems: devStore.items,
                    celebratingUntil: devStore.celebratingUntil,
                    isMusicPlaying: music.isPlaying,
                    reactToMusic: reactToMusic,
                    upcomingMeeting: liveMeeting,
                    reactToCalendar: reactToCalendar,
                    isCameraActive: observer.isCameraActive,
                    isMicActive: observer.isMicActive,
                    thermalState: observer.thermalState,
                    isMemoryPressured: observer.isMemoryPressured,
                    batteryPercentage: observer.batteryPercentage,
                    isCharging: observer.isCharging,
                    isPluggedIn: observer.isPluggedIn,
                    reactToSystem: reactToSystem,
                    lastActivityAt: observer.lastActivityAt,
                    now: date
                )
                let mood = inputs.resolveMood()
                let isVibing = reactToMusic && music.isPlaying
                let t = date.timeIntervalSinceReferenceDate
                let (musicMetrics, audioEnv, musicVibe) = observer.sampleAudioMetrics(at: t, isPlaying: isVibing)
                let musicTint = resolvedMusicTint(isVibing: isVibing)
                let reaction = resolvedReaction(at: date)
                let freshGaze: CGPoint? = (trackCursor && date.timeIntervalSince(lastGazeMoveAt) < 1.5) ? gaze : nil

                return AgentFaceFrameContext(
                    mood: mood,
                    reaction: reaction,
                    drag: observer.dragState,
                    isMuted: observer.isAudioMuted,
                    musicListening: isVibing,
                    musicVibe: musicVibe,
                    musicMetrics: musicMetrics,
                    audioEnvelope: audioEnv,
                    musicTint: musicTint,
                    gaze: freshGaze,
                    isUserTyping: observer.isUserActivelyTyping(at: date),
                    appSwitchLookX: observer.appSwitchLookX(at: date),
                    sparkleNonce: observer.sparkleEventNonce,
                    sparkleColor: observer.lastSparkleColor
                )
            }
        )
    }

    private func resolvedReaction(at date: Date) -> (reaction: AgentFaceReaction, age: TimeInterval)? {
        if let direct = observer.currentReaction(at: date) {
            return direct
        }
        guard reactToMusic, let cueReaction = MascotMusicCue.shared.reaction else { return nil }
        let age = date.timeIntervalSince(MascotMusicCue.shared.reactionAt)
        switch cueReaction {
        case .newTrack where age >= 0 && age < AgentFaceReaction.trackChange.duration:
            return (.trackChange, age)
        case .skip where age >= 0 && age < AgentFaceReaction.trackSkip.duration:
            return (.trackSkip, age)
        default:
            return nil
        }
    }

    private func resolvedMusicAccentColor() -> Color {
        if let tint = resolvedMusicTint(isVibing: true) {
            return Color(red: tint.r, green: tint.g, blue: tint.b)
        }
        return Color(red: 0.88, green: 0.61, blue: 0.42)
    }

    private func resolvedMusicTint(isVibing: Bool) -> (r: Double, g: Double, b: Double)? {
        guard isVibing, playerColorTinting else { return nil }
        guard let rgb = music.avgColor.usingColorSpace(.sRGB) else { return nil }
        let r = max(0.55, Double(rgb.redComponent))
        let g = max(0.55, Double(rgb.greenComponent))
        let b = max(0.55, Double(rgb.blueComponent))
        return (r, g, b)
    }
}

/// Idle-only fallback when Pixel Mascots style is active alongside `showNotHumanFace`.
struct IdleAgentFaceView: View {
    let cameraHeight: CGFloat

    var body: some View {
        DevAgentFaceLiveActivity(cameraHeight: cameraHeight)
    }
}

/// Legacy preview/component wrapper kept for source compatibility.
struct AnimatedFace: View {
    var height: CGFloat = 112
    var width: CGFloat = 204
    var mood: AgentFaceMood = .idle

    var body: some View {
        AgentFaceCanvas(mood: mood)
            .frame(width: width, height: height)
    }
}

#Preview {
    ZStack {
        Color.black
        AnimatedFace(height: 76, width: 144, mood: .working)
    }
    .frame(width: 220, height: 110)
}
