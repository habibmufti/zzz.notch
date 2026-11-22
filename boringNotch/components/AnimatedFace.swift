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

    /// 3-harmonic hand-drawn organic wave (directly adapted from Living Dynamic Notch PoC).
    static func sampleWave(u: Double, seed1: Double, seed2: Double) -> CGFloat {
        let clamped = max(0, min(1, u))
        let env = 0.42 + 0.58 * pow(sin(clamped * .pi), 0.55)
        let w1 = sin(clamped * .pi * 6.2 * seed1) * 2.2
        let w2 = sin(clamped * .pi * 13.4 * seed2 + 1.1) * 0.95
        let w3 = cos(clamped * .pi * 2.9 + seed1 * 1.8) * 0.65
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
        case .sleep, .sleepy, .lowBattery, .overheated, .strained, .done, .onCallCam, .onCallMic:
            return .zero
        case .working:
            return .zero
        case .waiting:
            let slot = Int(floor(t / 3.2))
            let r = hash01(slot &+ 91)
            if r < 0.74 { return .zero }
            return CGPoint(x: r < 0.87 ? -5.0 : 5.0, y: 0)
        case .meeting:
            let slot = Int(floor(t / 3.0))
            let r = hash01(slot &+ 137)
            return CGPoint(x: r < 0.55 ? 0 : (r < 0.78 ? -7.0 : 7.0), y: -1.5)
        case .listening:
            let slot = Int(floor(t / 3.8))
            let r = hash01(slot &+ 211)
            if r < 0.58 { return .zero }
            if r < 0.79 { return CGPoint(x: 9.0, y: -1.0) }
            return CGPoint(x: -9.0, y: -1.0)
        case .idle:
            let slot = Int(floor(t / 3.8))
            let r = hash01(slot &+ 43)
            if r < 0.54 { return .zero }
            if r < 0.76 { return CGPoint(x: 11.0, y: 0.5) }
            if r < 0.94 { return CGPoint(x: -11.0, y: 0.5) }
            return CGPoint(x: 0, y: 4.5)
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
        if hash01(slot &+ 59) < 0.22 {
            let secondAt = blinkAt + 0.21
            if local >= secondAt && local <= secondAt + 0.095 {
                return true
            }
        }
        return false
    }
}

// MARK: - Living Avatar Physics Engine (15 Springs + 3-Phase Scribble + Particles)

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

/// Kept non-`@Published` so stepping inside `TimelineView` never triggers extra
/// SwiftUI body invalidations.
final class AgentFaceEngine: ObservableObject {
    // Springs (critically damped — zero motion-sickness overshoot wobble)
    var gazeX = FaceSpring(initial: 0, stiffness: 240, damping: 26)
    var gazeY = FaceSpring(initial: 0, stiffness: 240, damping: 26)
    var scaleX = FaceSpring(initial: 1, stiffness: 230, damping: 24)
    var scaleY = FaceSpring(initial: 1, stiffness: 230, damping: 24)
    var inwardTilt = FaceSpring(initial: 0, stiffness: 210, damping: 24)
    var eyelidTop = FaceSpring(initial: 0, stiffness: 185, damping: 22)
    var eyelidBottom = FaceSpring(initial: 0, stiffness: 210, damping: 22)
    var blink = FaceSpring(initial: 0, stiffness: 460, damping: 28)
    var mouthAmp = FaceSpring(initial: 0, stiffness: 180, damping: 20)
    var penAlpha = FaceSpring(initial: 0, stiffness: 190, damping: 22)
    var eyeSpacing = FaceSpring(initial: 18, stiffness: 210, damping: 22)
    var eyeLiftY = FaceSpring(initial: 0, stiffness: 195, damping: 22)
    var glowIntensity = FaceSpring(initial: 0, stiffness: 120, damping: 18)
    var red = FaceSpring(initial: 0.90, stiffness: 160, damping: 22)
    var green = FaceSpring(initial: 0.91, stiffness: 160, damping: 22)
    var blue = FaceSpring(initial: 1.00, stiffness: 160, damping: 22)

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
    private var lastTimestamp: TimeInterval?
    private var elapsed: Double = 0
    private var lastMood: AgentFaceMood = .idle

    init(initialMood: AgentFaceMood = .idle) {
        self.lastMood = initialMood
        if initialMood == .working {
            penAlpha.value = 1; penAlpha.target = 1
            eyeLiftY.value = -9; eyeLiftY.target = -9
            eyeSpacing.value = 21; eyeSpacing.target = 21
            inwardTilt.value = 0.17; inwardTilt.target = 0.17
        }
    }

    func step(frame: AgentFaceFrameContext, at timestamp: TimeInterval) {
        let rawDT = lastTimestamp.map { timestamp - $0 } ?? 0
        lastTimestamp = timestamp
        let dt = min(max(rawDT, 0), 1.0 / 30.0)
        elapsed += dt
        let cgDT = CGFloat(dt)

        let mood = frame.mood
        let reaction = frame.reaction?.reaction
        let rAge = frame.reaction?.age ?? 0

        // Reset scribble cleanly when entering `.working`.
        if mood == .working && lastMood != .working {
            scribbleProg = 0
            scribblePhase = .writing
            scribblePhaseTime = 0
            scribbleReturnT = 0
        }
        if mood == .done && lastMood != .done {
            spawnSparkles(count: 10, color: Color(red: 0.45, green: 0.95, blue: 0.66))
        }
        lastMood = mood

        // Spawn sparkles on external Layer 3 / Shelf events.
        if frame.sparkleNonce != lastSparkleNonce {
            lastSparkleNonce = frame.sparkleNonce
            let c = frame.sparkleColor
            spawnSparkles(count: 10, color: Color(red: c.r, green: c.g, blue: c.b))
        }

        // 1. 3-Phase Working Scribble Engine (writing 1.32s -> pause 0.22s -> return arc 0.28s)
        let spanHalf: CGFloat = 29
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
                    // Crisp left carriage-return saccade impulse.
                    gazeX.impulse(-95)
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
                        x: 20 + CGFloat(jitter) * 8,
                        y: -6,
                        vx: 5.5 + CGFloat(jitter) * 3.5,
                        vy: -12.5 - CGFloat(jitter) * 4.5,
                        life: 0,
                        maxLife: 1.85
                    )
                )
                nextSleepZAt = elapsed + 1.0
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
            sparkles[i].vy += 38 * cgDT
            if sparkles[i].life >= sparkles[i].maxLife {
                sparkles.remove(at: i)
            }
        }

        // 4. Layer 1 Base Targets (steady poses — zero continuous bounce/sway!)
        let grooveMult: Double = {
            if frame.isMuted { return 0 }
            if mood.isOnCall { return 0.2 }
            if mood == .sleep { return 0.1 }
            if mood == .sleepy { return 0.25 }
            if mood == .working { return 0.35 }
            return 1.0
        }()

        var tGazeX: CGFloat = 0
        var tGazeY: CGFloat = 0
        var tScaleX: CGFloat = 1.0
        var tScaleY: CGFloat = 1.0
        var tInward: CGFloat = 0
        var tTopLid: CGFloat = 0
        var tBotLid: CGFloat = 0
        var tEyeSpacing: CGFloat = 18.5
        var tEyeLiftY: CGFloat = 0
        var tR: Double = 0.90, tG: Double = 0.91, tB: Double = 1.00

        let isPlayingUnmuted = frame.musicListening && !frame.isMuted
        let env = frame.audioEnvelope

        // Vocal-reactive humming mouth when listening to Chill/Groove/Melancholy
        let showHummingMouth = isPlayingUnmuted
            && mood == .listening
            && reaction == nil
            && (frame.musicVibe == .groove || frame.musicVibe == .chill || frame.musicVibe == .melancholy)
        mouthAmp.target = showHummingMouth
            ? CGFloat(0.24 + env.envMid * 1.15 * grooveMult)
            : 0
        glowIntensity.target = isPlayingUnmuted
            ? CGFloat(0.24 + env.envRms * 0.85 * grooveMult)
            : 0

        switch mood {
        case .working:
            tEyeSpacing = 21.5
            tEyeLiftY = -9.5
            let trackX = scribblePhase == .returning ? -spanHalf * 0.42 : penX * 0.44
            tGazeX = trackX
            tGazeY = 3.5 + (scribblePhase == .writing ? penY * 0.32 : -0.8)
            tInward = 0.17
            tTopLid = 0.08
            tScaleX = 0.95
            tScaleY = 0.94

        case .idle:
            if let gaze = frame.gaze {
                tGazeX = gaze.x * 13.0
                tGazeY = gaze.y * 6.5
            } else if let switchX = frame.appSwitchLookX {
                tGazeX = switchX * 70
            } else if frame.isUserTyping {
                tGazeX = 3.0
                tGazeY = 4.0
            } else {
                let sac = FaceSaccade.discreteLook(at: timestamp, mood: .idle)
                tGazeX = sac.x
                tGazeY = sac.y
            }

        case .done:
            tScaleX = 1.06
            tScaleY = 0.95
            tBotLid = 0.62 // Happy ^ ^ cheek-squint arch!
            tR = 0.45; tG = 0.95; tB = 0.66

        case .waiting:
            let sac = FaceSaccade.discreteLook(at: timestamp, mood: .waiting)
            tGazeX = sac.x
            tGazeY = -2.0
            tScaleX = 1.04
            tScaleY = 1.12
            tR = 1.00; tG = 0.86; tB = 0.22

        case .meeting:
            let sac = FaceSaccade.discreteLook(at: timestamp, mood: .meeting)
            tGazeX = sac.x
            tGazeY = -2.5
            tScaleX = 1.02
            tScaleY = 1.06
            tR = 0.42; tG = 0.88; tB = 1.00

        case .onCallCam, .onCallMic:
            // Steady calm gaze, sleep locked out, music dampened 80%.
            tScaleX = 0.98
            tScaleY = 0.98
            tTopLid = 0.06
            tBotLid = 0.08
            tR = 0.90; tG = 0.92; tB = 1.00

        case .listening:
            let sac = FaceSaccade.discreteLook(at: timestamp, mood: .listening)
            tGazeX = frame.gaze.map { $0.x * 12.0 } ?? sac.x
            tGazeY = frame.gaze.map { $0.y * 5.5 } ?? sac.y
            tEyeLiftY = -4.0

            switch frame.musicVibe {
            case .chill:
                tTopLid = min(0.42, 0.26 + CGFloat(env.envMid * 0.14))
                tBotLid = 0.18 + CGFloat(env.envMid * 0.12)
                tScaleX = 1.04
                tScaleY = 0.88
                tR = 0.86; tG = 0.84; tB = 0.98
            case .melancholy:
                tInward = -0.14
                tTopLid = 0.22
                tBotLid = 0.10
                tScaleY = 0.92
                tR = 0.62; tG = 0.76; tB = 0.98
            case .groove:
                tBotLid = 0.28 + CGFloat(env.envMid * 0.18)
                tTopLid = 0.04
                tR = 0.82; tG = 0.88; tB = 1.00
            case .hype:
                tInward = 0.08
                tScaleX = 1.02
                tScaleY = 1.04
                tR = 0.96; tG = 0.62; tB = 0.96
            case .rock:
                tInward = 0.22
                tTopLid = 0.18
                tScaleX = 1.04
                tR = 1.00; tG = 0.48; tB = 0.44
            }

            if let tint = frame.musicTint {
                tR = tR * 0.55 + tint.r * 0.45
                tG = tG * 0.55 + tint.g * 0.45
                tB = tB * 0.55 + tint.b * 0.45
            }

        case .overheated:
            tInward = -0.12
            tTopLid = 0.26
            tScaleY = 0.84
            tR = 1.00; tG = 0.54; tB = 0.28

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
            tR = 0.96; tG = 0.42; tB = 0.42

        case .sleepy:
            // Clean chunky horizontal bars (never clipped by eyelids).
            tGazeY = 3.0
            tTopLid = 0
            tBotLid = 0
            tScaleX = 1.16
            tScaleY = 0.24
            tR = 0.84; tG = 0.84; tB = 0.96

        case .sleep:
            // Crisp visible `- -` sleeping bars + gentle drifting 'z' particles.
            tGazeY = 4.0
            tTopLid = 0
            tBotLid = 0
            tScaleX = 1.18
            tScaleY = 0.14
            tR = 0.78; tG = 0.80; tB = 0.95
        }

        // 5. Blink Target
        var tBlink: CGFloat = 0
        if reaction == .wake {
            // 1.2s choreographed wake-up: `- -` closed -> stretch -> double-blink greeting -> smile
            if rAge < 0.28 {
                tScaleX = 1.18; tScaleY = 0.14; tTopLid = 0; tBotLid = 0
            } else if rAge < 0.62 {
                tScaleX = 0.92; tScaleY = 1.16; tTopLid = 0; tBotLid = 0
            } else if rAge < 0.92 {
                tBlink = ((rAge > 0.68 && rAge < 0.76) || (rAge > 0.81 && rAge < 0.89)) ? 1 : 0
                tBotLid = 0.24
            } else {
                tBotLid = 0.36
            }
        } else if reaction != .failed && reaction != .poke && mood != .sleep {
            tBlink = FaceSaccade.isBlinking(at: timestamp, mood: mood) ? 1 : 0
        }

        // 6. Layer 3 One-Shot Reaction Overrides
        switch reaction {
        case .airpods:
            tScaleX = 1.10; tScaleY = 1.10; tBotLid = 0.36; tTopLid = 0
            tR = 0.56; tG = 0.88; tB = 1.00
        case .wifiLost:
            tScaleX = 0.94; tScaleY = 0.88; tTopLid = 0.22; tInward = -0.14
            tR = 0.98; tG = 0.78; tB = 0.28
        case .wifiRestored:
            tScaleX = 1.08; tScaleY = 1.04; tBotLid = 0.56; tTopLid = 0
            tR = 0.36; tG = 0.92; tB = 0.68
        case .mute:
            tTopLid = 0.36; tBotLid = 0.14; tScaleY = 0.86
        case .vol100:
            tScaleX = 1.20; tScaleY = 1.22; tTopLid = 0; tBotLid = 0
        case .charged:
            tScaleX = 1.10; tScaleY = 1.12; tBotLid = 0.42; tTopLid = 0
            tR = 0.36; tG = 0.96; tB = 0.56
        case .poke:
            tScaleX = 1.08; tScaleY = 0.96; tBotLid = 0.66; tTopLid = 0
        case .trackSkip:
            tGazeX = 14.0
        case .trackChange:
            tScaleX = 1.06; tScaleY = 1.08; tBotLid = 0.26
        case .failed:
            tR = 1.00; tG = 0.42; tB = 0.42
        case .wake, .curious, .none:
            break
        }

        // 7. Layer 2 Spatial Override — Drag-to-Shelf (highest gaze priority!)
        if frame.drag.active {
            tGazeX = frame.drag.offsetX * 15.0
            tGazeY = frame.drag.offsetY * 9.0
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
            let spd = 22.0 + h * 30.0
            sparkles.append(
                SparkleParticle(
                    x: CGFloat((h - 0.5) * 32),
                    y: CGFloat((FaceSaccade.hash01(i &+ 9) - 0.5) * 14),
                    vx: CGFloat(cos(ang) * spd),
                    vy: CGFloat(sin(ang) * spd - 10),
                    size: CGFloat(1.8 + h * 1.8),
                    life: 0,
                    maxLife: 0.60 + h * 0.30,
                    color: color
                )
            )
        }
    }

    var areSpringsSettled: Bool {
        gazeX.isSettled && gazeY.isSettled && scaleX.isSettled && scaleY.isSettled
            && eyelidTop.isSettled && eyelidBottom.isSettled && inwardTilt.isSettled
            && blink.isSettled && penAlpha.isSettled && sparkles.isEmpty
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
        if ctx.reaction != nil || ctx.drag.active || ctx.gaze != nil || !engine.areSpringsSettled {
            return 1.0 / 30.0
        }
        switch ctx.mood {
        case .working, .listening, .overheated:
            return 1.0 / 30.0
        case .waiting, .done, .meeting, .onCallCam, .onCallMic, .strained, .idle, .sleepy, .lowBattery:
            return 1.0 / 20.0
        case .sleep:
            return 1.0 / 12.0
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
                let eyeCenterY = h * 0.44 + engine.eyeLiftY.value
                let reaction = frame.reaction?.reaction
                let isPureMusic = frame.mood == .listening && reaction == nil && !frame.isMuted
                let eyeColor = Color(
                    red: Double(min(max(engine.red.value, 0), 1)),
                    green: Double(min(max(engine.green.value, 0), 1)),
                    blue: Double(min(max(engine.blue.value, 0), 1))
                )

                // 1. Ambient Radial RMS Glow behind eyes (music-reactive without moving eyes!)
                let glow = max(0, Double(engine.glowIntensity.value))
                if glow > 0.02 {
                    let radius = 26 + glow * 26
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
                                eyeColor.opacity(min(0.34, glow * 0.34)),
                                eyeColor.opacity(0)
                            ]),
                            center: CGPoint(x: cx, y: eyeCenterY),
                            startRadius: 3,
                            endRadius: radius
                        )
                    )
                }

                // 2. Left (-1) & Right (+1) Eyes with 3D Spherical Foreshortening + Eyelids
                let gx = engine.gazeX.value
                let gy = engine.gazeY.value
                let blinkVal = min(max(engine.blink.value, 0), 1)
                let openY = max(0.08, 1.0 - blinkVal * 0.92)
                let baseW: CGFloat = 15.2
                let baseH: CGFloat = 26.2
                let spacing = engine.eyeSpacing.value
                let topLid = max(0, engine.eyelidTop.value)
                let botLid = max(0, engine.eyelidBottom.value)
                let lookRatio = max(-1, min(1, gx / 16.0))

                for (index, side) in [-1.0, 1.0].enumerated() {
                    let sideF = CGFloat(side)
                    let sphericalSide = sideF * lookRatio
                    let depthScale = 1.0 + sphericalSide * 0.07
                    let widthPersp = 1.0 + sphericalSide * 0.09 - (sphericalSide < 0 ? abs(sphericalSide) * 0.09 : 0)

                    let ex = cx + gx + sideF * spacing * (1.0 - abs(lookRatio) * 0.05)
                    let ey = eyeCenterY + gy
                    let ew = baseW * engine.scaleX.value * widthPersp
                    var eh = max(3.2, baseH * engine.scaleY.value * openY * depthScale)

                    if reaction == .curious {
                        eh *= (index == 0 ? 0.74 : 1.16)
                    }

                    var eyeCtx = ctx
                    eyeCtx.translateBy(x: ex, y: ey)
                    eyeCtx.rotate(by: .radians(Double(sideF * -engine.inwardTilt.value)))

                    if reaction == .failed {
                        // Expressive > < eyes for failed runs.
                        var chevron = Path()
                        let hw = ew * 0.45
                        let hh: CGFloat = 8.5
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
                            style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)
                        )
                        continue
                    }

                    // Pill eye body with soft glow
                    let pillRect = CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh)
                    let pillPath = Path(roundedRect: pillRect, cornerRadius: min(ew, eh) * 0.48)
                    eyeCtx.drawLayer { layerCtx in
                        layerCtx.addFilter(.shadow(color: eyeColor.opacity(0.45), radius: 5, x: 0, y: 0))
                        layerCtx.fill(pillPath, with: .color(eyeColor))
                    }

                    // Starry highlight glint during AirPods / Charged connect
                    if reaction == .airpods || reaction == .charged {
                        let glintRect = CGRect(x: -ew * 0.24, y: -eh * 0.28, width: 4.4, height: 4.4)
                        eyeCtx.fill(Path(ellipseIn: glintRect), with: .color(.white))
                    }

                    // Top Eyelid Curtain (Working focus, Rock fierce, Sleepy/Sleep, Mute)
                    if topLid > 0.02 {
                        var lidCtx = eyeCtx
                        let browAng: Double = (frame.mood == .working || (isPureMusic && frame.musicVibe == .rock))
                            ? 0.17
                            : (frame.mood == .overheated || (isPureMusic && frame.musicVibe == .melancholy) ? -0.15 : -0.06)
                        lidCtx.rotate(by: .radians(Double(sideF) * browAng))
                        let lidRect = CGRect(x: -ew, y: -eh / 2 - 5, width: ew * 2, height: eh * topLid * 1.10 + 5)
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
                        arch.addLine(to: CGPoint(x: ew, y: eh + 4))
                        arch.addLine(to: CGPoint(x: -ew, y: eh + 4))
                        arch.closeSubpath()
                        eyeCtx.fill(arch, with: .color(.black))
                    }
                }

                // 3. Working Desk: 3-Phase Organic Multi-Harmonic Ink + Teardrop Quill Pen Nib
                let penA = min(max(Double(engine.penAlpha.value), 0), 1)
                if penA > 0.02 && reaction != .failed {
                    drawOrganicScribbleAndQuill(
                        in: &ctx,
                        cx: cx,
                        deskY: min(h - 9, eyeCenterY + 33),
                        alpha: penA,
                        t: t,
                        color: eyeColor
                    )
                }

                // 4. Music Mouth: Vocal Humming Wave (Ballad/Chill/Groove) or 5-Bar Mini EQ (Hype/Rock)
                if isPureMusic && (frame.musicVibe == .hype || frame.musicVibe == .rock) {
                    drawMiniEqualizerMouth(
                        in: &ctx,
                        cx: cx,
                        my: eyeCenterY + 23,
                        bands: frame.musicMetrics.bands,
                        color: eyeColor
                    )
                } else {
                    let mAmp = max(0, CGFloat(engine.mouthAmp.value))
                    if mAmp > 0.03 && reaction != .failed {
                        drawVocalHummingMouth(
                            in: &ctx,
                            cx: cx,
                            baseY: eyeCenterY + 22,
                            amp: mAmp,
                            t: t,
                            color: eyeColor
                        )
                    }
                }

                // 5. Overheated sweat bead
                if frame.mood == .overheated {
                    let phase = t.truncatingRemainder(dividingBy: 2.0) / 2.0
                    let dropX = cx + spacing + 13
                    let dropY = eyeCenterY - 10 + CGFloat(phase) * 16
                    let alpha = sin(phase * .pi)
                    let drop = CGRect(x: dropX - 2, y: dropY - 3, width: 4, height: 6)
                    ctx.fill(
                        Path(ellipseIn: drop),
                        with: .color(Color(red: 0.52, green: 0.86, blue: 1.0).opacity(alpha * 0.9))
                    )
                }

                // 6. Sleep Floating 'z' Particles
                for z in engine.sleepZs {
                    let u = z.life / z.maxLife
                    let alpha = u < 0.2 ? (u / 0.2) : max(0, 1.0 - (u - 0.2) / 0.8)
                    let fontSize = 9.0 + u * 4.5
                    let text = Text("z")
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.65, green: 0.71, blue: 0.99).opacity(alpha * 0.85))
                    ctx.draw(text, at: CGPoint(x: cx + z.x, y: eyeCenterY + z.y))
                }

                // 7. Layer 3 Floating Badges (AirPods / Wi-Fi '?' / Mute)
                if reaction == .airpods || reaction == .wifiLost || reaction == .mute {
                    let bx = cx + 44
                    let by = eyeCenterY - 10
                    let badgeRect = CGRect(x: bx - 9.5, y: by - 9.5, width: 19, height: 19)
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
        let spanX: CGFloat = 58
        let startX = cx - spanX / 2
        let prog = max(0, min(1, engine.scribbleProg))
        let isReturn = engine.scribblePhase == .returning
        let isPause = engine.scribblePhase == .pause
        let inkFade = isReturn ? max(0, 1.0 - engine.scribbleReturnT * 1.25) : 1.0

        // Organic Multi-Harmonic Ink Trail
        if inkFade > 0.02 && (isReturn || prog > 0.01) {
            let samples = 48
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
                ctx.stroke(
                    trail,
                    with: .color(color.opacity(alpha * 0.9 * inkFade)),
                    style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // True Teardrop Quill Pen Nib with Parabolic Return Arc + Subtle Wrist Jitter
        let tipX = startX + CGFloat(prog) * spanX
        let waveY = OrganicScribble.sampleWave(u: prog, seed1: engine.scribbleSeed1, seed2: engine.scribbleSeed2)
        let liftY: CGFloat = {
            if isPause { return -3.2 }
            if isReturn { return CGFloat(-sin(engine.scribbleReturnT * .pi) * 12.5) }
            return 0
        }()
        let tipY = deskY + (isReturn ? 0 : waveY) + liftY
        let wristJitter: Double = {
            if engine.scribblePhase == .writing {
                return sin(t * 28) * 0.10 + cos(t * 17) * 0.04
            }
            return isReturn ? -0.18 : 0.04
        }()

        var nibCtx = ctx
        nibCtx.translateBy(x: tipX, y: tipY)
        nibCtx.rotate(by: .radians(0.66 + wristJitter))

        var quill = Path()
        quill.move(to: .zero)
        quill.addCurve(
            to: CGPoint(x: 0, y: -14.8),
            control1: CGPoint(x: -4.8, y: -4.6),
            control2: CGPoint(x: -4.5, y: -12.3)
        )
        quill.addCurve(
            to: .zero,
            control1: CGPoint(x: 4.5, y: -12.3),
            control2: CGPoint(x: 4.8, y: -4.6)
        )
        quill.closeSubpath()
        nibCtx.fill(quill, with: .color(color.opacity(alpha)))

        // Quill nib center slit detail
        var slit = Path()
        slit.move(to: CGPoint(x: 0, y: -1.0))
        slit.addLine(to: CGPoint(x: 0, y: -6.5))
        nibCtx.stroke(
            slit,
            with: .color(Color.black.opacity(0.60 * alpha)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
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
        let halfSpan = 19 + amp * 5.5
        let waveH = 1.4 + amp * 5.5
        var wave = Path()
        let steps = 32
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let x = cx - halfSpan + CGFloat(u) * halfSpan * 2
            let win = sin(u * .pi)
            let yOff = (sin(u * .pi * 4 - t * 9.5) * 0.72 + sin(u * .pi * 8 + t * 13) * 0.28) * Double(waveH) * win
            let pt = CGPoint(x: x, y: baseY + CGFloat(yOff))
            if i == 0 { wave.move(to: pt) } else { wave.addLine(to: pt) }
        }
        ctx.stroke(
            wave,
            with: .color(color.opacity(min(1, Double(amp) * 1.15))),
            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawMiniEqualizerMouth(
        in ctx: inout GraphicsContext,
        cx: CGFloat,
        my: CGFloat,
        bands: [Double],
        color: Color
    ) {
        let count = 5
        let barW: CGFloat = 2.6
        let spacing: CGFloat = 4.2
        let totalW = CGFloat(count - 1) * spacing
        let maxH: CGFloat = 11.5

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

// MARK: - Dropped Chin Container & Unified Mac Companion View

struct AgentFaceDroppedChinView: View {
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    let meetingBadge: UpcomingMeetingCue?
    let onCallDotColor: Color?
    let trackCursor: Bool
    let onGazeChanged: (CGPoint?, Date) -> Void
    let onMeetingTap: ((UpcomingMeetingCue) -> Void)?
    let contextProvider: (Date) -> AgentFaceFrameContext

    static let faceHeight: CGFloat = 76
    static let faceWidth: CGFloat = 144

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: max(Self.faceWidth, cameraWidth), height: cameraHeight)

            ZStack(alignment: .bottom) {
                AgentFaceCanvas(contextProvider: contextProvider)
                    .frame(width: Self.faceWidth, height: Self.faceHeight)

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
                    .padding(.bottom, 4)
                    .help("\(meetingBadge.title) · Click to join")
                }
            }
            .overlay(alignment: .topTrailing) {
                if let onCallDotColor {
                    Circle()
                        .fill(onCallDotColor)
                        .frame(width: 6.5, height: 6.5)
                        .shadow(color: onCallDotColor.opacity(0.85), radius: 4)
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                }
            }
            .overlay {
                FaceTrackingOverlay(enabled: trackCursor, onGazeChanged: onGazeChanged)
            }
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
        let onCallColor: Color? = {
            guard reactToSystem else { return nil }
            if observer.isCameraActive { return Color(red: 0.29, green: 0.87, blue: 0.50) }
            if observer.isMicActive { return Color(red: 0.98, green: 0.57, blue: 0.24) }
            return nil
        }()

        AgentFaceDroppedChinView(
            cameraWidth: vm.closedNotchSize.width,
            cameraHeight: cameraHeight,
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

                // 1.5s stillness auto-reset on idle proximity cursor gaze.
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
    var height: CGFloat = 76
    var width: CGFloat = 144
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
