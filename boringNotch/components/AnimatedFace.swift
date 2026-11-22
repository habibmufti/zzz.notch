//
//  AnimatedFace.swift
//  zzz.notch
//
//  Unified procedural Mac companion face rendered in a dropped chin below the
//  camera cutout. Uses steady poses with crisp discrete saccades (zero
//  continuous swaying/bobbing to prevent motion sickness), a live scribbling
//  nib animation while agents work, genre-adaptive music expressions + mini
//  mouth equalizer, upcoming calendar badges, event-driven system health alerts,
//  and real-time interactivity (cursor gaze, app switches, clicks/typing wake).
//

import AppKit
import Combine
import Defaults
import IOKit.ps
import SwiftUI

// MARK: - Moods & Reactions

enum AgentFaceMood: String, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case waiting
    case done
    case listening
    case meeting
    case overheated
    case strained
    case lowBattery
    case sleepy
    case sleep

    static let sleepyAfterSeconds: TimeInterval = 20
    static let sleepAfterSeconds: TimeInterval = 45

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
    case failed
    case charged
    case curious
    case poke
    case trackChange
    case trackSkip

    var duration: TimeInterval {
        switch self {
        case .failed: 3.0
        case .charged: 2.2
        case .curious: 1.8
        case .poke: 1.4
        case .trackChange: 1.5
        case .trackSkip: 1.2
        }
    }
}

/// Expressive music personality inferred from track genre metadata + live FFT bands.
enum MusicVibe: String, CaseIterable, Equatable, Sendable {
    case chill
    case groove
    case hype
    case rock
    case melancholy
}

struct MusicAudioMetrics: Equatable, Sendable {
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    var overall: Double = 0
    var bassPunch: Double = 0
    var bands: [Double] = [0, 0, 0, 0, 0, 0]

    static let silent = MusicAudioMetrics()

    /// Extracts bass (60–380 Hz), mid/vocal (380–2.5 kHz), and treble (2.5–16 kHz)
    /// from AudioCaptureManager's 6 log-spaced FFT bands.
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

    /// Fallback vibe inference from live FFT energy when no genre metadata is available.
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

    /// Maps an iTunes `primaryGenreName` plus track/album/artist text into a `MusicVibe`.
    /// Returns `nil` when metadata gives no clear signal so callers can fall back to live FFT.
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
        if chillKeywords.contains(where: { text.contains($0) }) {
            return .chill
        }
        if melancholyKeywords.contains(where: { text.contains($0) }) {
            return .melancholy
        }
        if rockKeywords.contains(where: { text.contains($0) }) {
            return .rock
        }
        if hypeKeywords.contains(where: { text.contains($0) }) {
            return .hype
        }
        if grooveKeywords.contains(where: { text.contains($0) }) {
            return .groove
        }
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

/// Pure snapshot of all module inputs used to resolve the Mac companion face's mood.
struct MacFaceInputs: Equatable, Sendable {
    let devItems: [SystemNotification]
    let celebratingUntil: [String: Date]
    let isMusicPlaying: Bool
    let reactToMusic: Bool
    let upcomingMeeting: UpcomingMeetingCue?
    let reactToCalendar: Bool
    let thermalState: SystemThermalState
    let isMemoryPressured: Bool
    let batteryPercentage: Int?
    let isCharging: Bool
    let isPluggedIn: Bool
    let reactToSystem: Bool
    let lastActivityAt: Date
    let now: Date

    var isLowBattery: Bool {
        guard let pct = batteryPercentage else { return false }
        return pct <= 15 && !isCharging && !isPluggedIn
    }

    /// Resolves the unified base mood across every module in strict priority order:
    /// Agent waiting > Imminent meeting > System critical (thermal/memory/battery)
    /// > Agent working > Agent celebrating > Music listening > Idle → Sleepy → Sleep.
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
    @Published private(set) var lastActivityAt = Date()
    @Published private(set) var detectedTrackGenre: String?
    @Published private(set) var musicVibeFromMetadata: MusicVibe?
    /// Brief subtle downward glance when the user is actively typing on the Mac.
    private(set) var lastTypingAt = Date.distantPast
    /// Brief saccade cue when the user switches apps.
    private(set) var lastAppSwitchAt = Date.distantPast
    private(set) var appSwitchGlanceX: CGFloat = 0

    private(set) var activeReaction: AgentFaceReaction?
    private(set) var reactionAt = Date.distantPast

    private var thermalObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    private var globalInputMonitor: Any?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var powerRunLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()
    private var lastNotificationID: String?
    private var genreLookupTask: Task<Void, Never>?
    private var genreCache: [String: String] = [:]
    private var smoothedBass: Double = 0
    private var rollingEnergy: Double = 0

    private init() {
        self.thermalState = SystemThermalState(ProcessInfo.processInfo.thermalState)
        refreshBatteryState(fireChargeReaction: false)
        installSystemObservers()
        installAppObservers()
        installUserActivityObservers()
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        if let appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver)
        }
        if let globalInputMonitor {
            NSEvent.removeMonitor(globalInputMonitor)
        }
        memoryPressureSource?.cancel()
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

    func triggerReaction(_ reaction: AgentFaceReaction) {
        activeReaction = reaction
        reactionAt = Date()
        lastActivityAt = Date()
    }

    func currentReaction(at now: Date) -> (reaction: AgentFaceReaction, age: TimeInterval)? {
        guard let activeReaction else { return nil }
        let age = now.timeIntervalSince(reactionAt)
        guard age >= 0, age < activeReaction.duration else { return nil }
        return (activeReaction, age)
    }

    /// True right after user types so the face glances subtly toward the screen.
    func isUserActivelyTyping(at now: Date) -> Bool {
        now.timeIntervalSince(lastTypingAt) < 1.8
    }

    /// Brief directional glance when switching apps (holds steady, never oscillates).
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
    }

    private func installUserActivityObservers() {
        // Wake & glance briefly when switching foreground apps (0% idle CPU).
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

        // Wake the face when the user clicks or types anywhere on the Mac.
        // Never reads key characters — only records activity timestamp (throttled).
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

    func sampleAudioMetrics(at t: Double, isPlaying: Bool) -> (metrics: MusicAudioMetrics, vibe: MusicVibe) {
        guard isPlaying else {
            smoothedBass = 0
            rollingEnergy = 0
            return (.silent, musicVibeFromMetadata ?? .groove)
        }

        let capture = AudioCaptureManager.shared
        let metrics: MusicAudioMetrics
        if capture.isCapturing, let bars = capture.latestLevelsSnapshot(), !bars.isEmpty {
            metrics = MusicAudioMetrics.from(bars: bars, previousBass: smoothedBass)
            smoothedBass = smoothedBass * 0.72 + metrics.bass * 0.28
            rollingEnergy = rollingEnergy == 0
                ? metrics.overall
                : rollingEnergy * 0.94 + metrics.overall * 0.06
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
                return 0.18 + 0.55 * max(0, sin(phase))
            }
            let level = bands.reduce(0, +) / 6.0
            metrics = MusicAudioMetrics(
                bass: (bands[0] + bands[1]) * 0.5,
                mid: (bands[2] + bands[3]) * 0.5,
                treble: (bands[4] + bands[5]) * 0.5,
                overall: level,
                bassPunch: bands[0] > 0.62 ? (bands[0] - 0.62) * 2.4 : 0,
                bands: bands
            )
            rollingEnergy = level
        }

        let resolvedVibe: MusicVibe
        if let metaVibe = musicVibeFromMetadata {
            resolvedVibe = metaVibe
        } else {
            let energySnapshot = MusicAudioMetrics(
                bass: smoothedBass > 0 ? smoothedBass : metrics.bass,
                mid: metrics.mid,
                treble: metrics.treble,
                overall: rollingEnergy > 0 ? rollingEnergy : metrics.overall,
                bassPunch: metrics.bassPunch,
                bands: metrics.bands
            )
            resolvedVibe = energySnapshot.inferredVibe()
        }

        return (metrics, resolvedVibe)
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

// MARK: - Discrete Saccade Planner (Steady Holds, Zero Motion Sickness)

enum FaceSaccade {
    /// Deterministic hash in 0..<1 for natural non-metronomic eye holds & blinks.
    static func hash01(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 32
        return Double(x % 10_000) / 10_000.0
    }

    /// Returns a **constant** look offset that holds completely still for 2.8–4.5s,
    /// then snaps cleanly to a new target via the spring engine (no sine wobble!).
    static func discreteLook(at t: TimeInterval, mood: AgentFaceMood) -> CGPoint {
        switch mood {
        case .sleep, .sleepy, .lowBattery, .overheated, .strained:
            return .zero
        case .working:
            // Eyes stay steady, gently glancing down toward the scribbling nib.
            return CGPoint(x: 0, y: 0.04)
        case .waiting:
            // Mostly steady straight ahead, occasional small attentive shift.
            let slot = Int(floor(t / 3.2))
            let r = hash01(slot &+ 91)
            if r < 0.72 { return .zero }
            return CGPoint(x: r < 0.86 ? -0.07 : 0.07, y: 0)
        case .meeting:
            let slot = Int(floor(t / 3.0))
            let r = hash01(slot &+ 137)
            return CGPoint(x: r < 0.5 ? 0 : (r < 0.75 ? -0.09 : 0.09), y: -0.02)
        case .done:
            return .zero
        case .listening:
            // Hold steady for ~3.5s per phrase, occasionally glance left/right.
            let slot = Int(floor(t / 3.6))
            let r = hash01(slot &+ 211)
            if r < 0.55 { return .zero }
            if r < 0.78 { return CGPoint(x: 0.13, y: -0.02) }
            return CGPoint(x: -0.13, y: -0.02)
        case .idle:
            // Classic video behavior: hold center, occasionally snap left/right & hold still.
            let slot = Int(floor(t / 3.8))
            let r = hash01(slot &+ 43)
            if r < 0.52 { return .zero }
            if r < 0.74 { return CGPoint(x: 0.16, y: 0.01) }
            if r < 0.94 { return CGPoint(x: -0.16, y: 0.01) }
            return CGPoint(x: 0, y: 0.07)
        }
    }

    /// Natural randomized single or occasional double blink inside each ~3.8s slot.
    static func isBlinking(at t: TimeInterval, mood: AgentFaceMood) -> Bool {
        guard mood != .sleep && mood != .sleepy else { return false }
        let slotLength = mood == .listening ? 4.2 : 3.8
        let slot = Int(floor(t / slotLength))
        let local = t - Double(slot) * slotLength
        let blinkAt = 0.6 + hash01(slot &+ 17) * (slotLength - 1.2)
        if local >= blinkAt && local <= blinkAt + 0.11 {
            return true
        }
        // ~20% chance of a quick expressive double-blink.
        if hash01(slot &+ 59) < 0.20 {
            let secondAt = blinkAt + 0.22
            if local >= secondAt && local <= secondAt + 0.10 {
                return true
            }
        }
        return false
    }
}

// MARK: - Procedural Pose & Spring Physics

/// Every pose is a small vector of normalized numbers; the canvas only draws these.
struct AgentFacePose: Equatable, Sendable {
    var eyeW: CGFloat
    var eyeH: CGFloat
    var lookX: CGFloat
    var lookY: CGFloat
    /// 0 upright … +1 inward fierce/focused tilt (\ /), -1 soft outer droop (/ \).
    var tilt: CGFloat
    /// 0 hidden … 1 active scribble/working mode.
    var scribble: CGFloat
    /// Color blend weights (interpolated smoothly by the spring).
    var red: Double
    var green: Double
    var blue: Double
    /// 0 normal … 1 happy smile arc.
    var smile: Double

    static func target(_ mood: AgentFaceMood, musicVibe: MusicVibe = .groove) -> AgentFacePose {
        switch mood {
        case .idle:
            // Chunky expressive tall pills matching the reference video (00:00–00:04).
            AgentFacePose(eyeW: 0.34, eyeH: 0.74, lookX: 0, lookY: 0, tilt: 0, scribble: 0, red: 0.88, green: 0.88, blue: 0.98, smile: 0)
        case .working:
            // Focused inward-angled eyes + scribbling nib below (video 00:05–00:16).
            AgentFacePose(eyeW: 0.34, eyeH: 0.66, lookX: 0, lookY: -0.06, tilt: 0.85, scribble: 1, red: 0.88, green: 0.88, blue: 0.98, smile: 0)
        case .waiting:
            AgentFacePose(eyeW: 0.36, eyeH: 0.86, lookX: 0, lookY: -0.06, tilt: 0, scribble: 0, red: 1.00, green: 0.86, blue: 0.22, smile: 0)
        case .done:
            AgentFacePose(eyeW: 0.36, eyeH: 0.56, lookX: 0, lookY: -0.03, tilt: 0, scribble: 0, red: 0.45, green: 0.95, blue: 0.66, smile: 1)
        case .listening:
            switch musicVibe {
            case .chill:
                AgentFacePose(eyeW: 0.40, eyeH: 0.36, lookX: 0, lookY: 0.03, tilt: 0, scribble: 0, red: 0.86, green: 0.84, blue: 0.98, smile: 0.60)
            case .groove:
                AgentFacePose(eyeW: 0.35, eyeH: 0.64, lookX: 0, lookY: -0.02, tilt: 0, scribble: 0, red: 0.82, green: 0.88, blue: 1.00, smile: 0.90)
            case .hype:
                AgentFacePose(eyeW: 0.35, eyeH: 0.72, lookX: 0, lookY: -0.06, tilt: 0.25, scribble: 0, red: 0.96, green: 0.62, blue: 0.96, smile: 0)
            case .rock:
                AgentFacePose(eyeW: 0.36, eyeH: 0.66, lookX: 0, lookY: -0.05, tilt: 1.0, scribble: 0, red: 1.00, green: 0.48, blue: 0.44, smile: 0)
            case .melancholy:
                AgentFacePose(eyeW: 0.34, eyeH: 0.60, lookX: 0, lookY: 0.04, tilt: -0.85, scribble: 0, red: 0.62, green: 0.76, blue: 0.98, smile: 0)
            }
        case .meeting:
            AgentFacePose(eyeW: 0.35, eyeH: 0.78, lookX: 0, lookY: -0.06, tilt: 0, scribble: 0, red: 0.44, green: 0.90, blue: 1.00, smile: 0)
        case .overheated:
            AgentFacePose(eyeW: 0.38, eyeH: 0.44, lookX: 0, lookY: 0.04, tilt: -0.55, scribble: 0, red: 1.00, green: 0.54, blue: 0.28, smile: 0)
        case .strained:
            AgentFacePose(eyeW: 0.42, eyeH: 0.26, lookX: 0, lookY: 0.02, tilt: 0.55, scribble: 0, red: 1.00, green: 0.78, blue: 0.30, smile: 0)
        case .lowBattery:
            AgentFacePose(eyeW: 0.42, eyeH: 0.22, lookX: 0, lookY: 0.08, tilt: -0.45, scribble: 0, red: 0.96, green: 0.42, blue: 0.42, smile: 0)
        case .sleepy:
            // Chunky crisp horizontal bars straight from video 00:18!
            AgentFacePose(eyeW: 0.46, eyeH: 0.18, lookX: 0, lookY: 0.05, tilt: 0, scribble: 0, red: 0.84, green: 0.84, blue: 0.96, smile: 0)
        case .sleep:
            AgentFacePose(eyeW: 0.44, eyeH: 0.06, lookX: 0, lookY: 0.10, tilt: 0, scribble: 0, red: 0.74, green: 0.74, blue: 0.90, smile: 0)
        }
    }
}

/// Critically damped spring following the target pose & discrete saccade target.
/// No overshoot wobble, no continuous oscillation.
final class AgentFaceEngine: ObservableObject {
    private(set) var pose: AgentFacePose
    private var velocity = [CGFloat](repeating: 0, count: 10)
    private var lastTimestamp: TimeInterval?

    init(initialMood: AgentFaceMood = .idle) {
        self.pose = .target(initialMood)
    }

    func step(
        to mood: AgentFaceMood,
        at timestamp: TimeInterval,
        musicVibe: MusicVibe = .groove,
        lookOverride: CGPoint = .zero,
        tintOverride: (r: Double, g: Double, b: Double)? = nil
    ) -> AgentFacePose {
        let dt: CGFloat
        if let last = lastTimestamp {
            dt = CGFloat(min(max(timestamp - last, 0), 1.0 / 30.0))
        } else {
            dt = 0
        }
        lastTimestamp = timestamp

        var target = AgentFacePose.target(mood, musicVibe: musicVibe)
        target.lookX += lookOverride.x
        target.lookY += lookOverride.y
        if let tint = tintOverride {
            target.red = target.red * 0.6 + tint.r * 0.4
            target.green = target.green * 0.6 + tint.g * 0.4
            target.blue = target.blue * 0.6 + tint.b * 0.4
        }

        var cur: [CGFloat] = [
            pose.eyeW, pose.eyeH, pose.lookX, pose.lookY, pose.tilt,
            pose.scribble, CGFloat(pose.red), CGFloat(pose.green), CGFloat(pose.blue), CGFloat(pose.smile)
        ]
        let tgt: [CGFloat] = [
            target.eyeW, target.eyeH, target.lookX, target.lookY, target.tilt,
            target.scribble, CGFloat(target.red), CGFloat(target.green), CGFloat(target.blue), CGFloat(target.smile)
        ]

        // Critically damped (c ≈ 2 * sqrt(k)): crisp snappy saccades with zero bounce wobble.
        let stiffness: CGFloat = 180
        let damping: CGFloat = 26
        for i in cur.indices {
            velocity[i] += (stiffness * (tgt[i] - cur[i]) - damping * velocity[i]) * dt
            cur[i] += velocity[i] * dt
        }

        pose = AgentFacePose(
            eyeW: max(0.05, cur[0]),
            eyeH: max(0.02, cur[1]),
            lookX: cur[2],
            lookY: cur[3],
            tilt: min(max(cur[4], -1), 1),
            scribble: min(max(cur[5], 0), 1),
            red: Double(min(max(cur[6], 0), 1)),
            green: Double(min(max(cur[7], 0), 1)),
            blue: Double(min(max(cur[8], 0), 1)),
            smile: Double(min(max(cur[9], 0), 1))
        )
        return pose
    }

    func isSettled(for mood: AgentFaceMood, musicVibe: MusicVibe = .groove) -> Bool {
        let target = AgentFacePose.target(mood, musicVibe: musicVibe)
        let diffs: [CGFloat] = [
            abs(pose.eyeW - target.eyeW),
            abs(pose.eyeH - target.eyeH),
            abs(pose.tilt - target.tilt),
            abs(pose.scribble - target.scribble),
            abs(CGFloat(pose.red - target.red)),
            abs(CGFloat(pose.green - target.green)),
            abs(CGFloat(pose.blue - target.blue)),
            abs(CGFloat(pose.smile - target.smile))
        ]
        let maxDiff = diffs.max() ?? 0
        let maxVel = velocity.map(abs).max() ?? 0
        return maxDiff < 0.008 && maxVel < 0.015
    }
}

// MARK: - Cursor Gaze Tracking

final class FaceTrackingNSView: NSView {
    var onGazeChanged: ((CGPoint?) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let expanded = bounds.insetBy(dx: -110, dy: -48)
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
        onGazeChanged?(CGPoint(x: nx, y: ny))
    }

    override func mouseExited(with event: NSEvent) {
        onGazeChanged?(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct FaceTrackingOverlay: NSViewRepresentable {
    let enabled: Bool
    let onGazeChanged: (CGPoint?) -> Void

    func makeNSView(context: Context) -> FaceTrackingNSView {
        let view = FaceTrackingNSView(frame: .zero)
        view.onGazeChanged = enabled ? onGazeChanged : nil
        return view
    }

    func updateNSView(_ view: FaceTrackingNSView, context: Context) {
        view.onGazeChanged = enabled ? onGazeChanged : nil
        if !enabled {
            onGazeChanged(nil)
        }
    }
}

// MARK: - Canvas Renderer

struct AgentFaceFrameContext {
    var mood: AgentFaceMood
    var reaction: (reaction: AgentFaceReaction, age: TimeInterval)? = nil
    var musicListening: Bool = false
    var musicVibe: MusicVibe = .groove
    var musicMetrics: MusicAudioMetrics = .silent
    var musicTint: (r: Double, g: Double, b: Double)? = nil
    var gaze: CGPoint? = nil
    var isUserTyping: Bool = false
    var appSwitchLookX: CGFloat? = nil
    var devActivity: String? = nil
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
        if ctx.reaction != nil || ctx.gaze != nil || !engine.isSettled(for: ctx.mood, musicVibe: ctx.musicVibe) {
            return 1.0 / 30.0
        }
        switch ctx.mood {
        case .working, .listening, .overheated:
            return 1.0 / 30.0
        case .waiting, .done, .meeting, .strained, .idle, .sleepy, .lowBattery:
            return 1.0 / 20.0
        case .sleep:
            return 1.0 / 8.0
        }
    }

    var body: some View {
        let probe = contextProvider(Date())
        TimelineView(.animation(minimumInterval: frameInterval(for: probe))) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let frame = contextProvider(now)
            let reaction = frame.reaction?.reaction

            // Compute a STEADY discrete look target (cursor > skip > app switch > typing > saccade).
            // All transitions go through the critically damped spring — zero sine-wave wobbling!
            let targetLook: CGPoint = {
                if let gaze = frame.gaze {
                    return CGPoint(x: gaze.x * 0.17, y: gaze.y * 0.08)
                }
                if reaction == .trackSkip {
                    return CGPoint(x: 0.18, y: 0)
                }
                if let switchX = frame.appSwitchLookX, frame.mood == .idle {
                    return CGPoint(x: switchX, y: 0)
                }
                if frame.isUserTyping && (frame.mood == .idle || frame.mood == .sleepy) {
                    // Gently look down toward what the user is typing (just like video 00:00–00:04!).
                    return CGPoint(x: 0.04, y: 0.06)
                }
                return FaceSaccade.discreteLook(at: t, mood: frame.mood)
            }()

            let p = engine.step(
                to: frame.mood,
                at: t,
                musicVibe: frame.musicVibe,
                lookOverride: targetLook,
                tintOverride: frame.mood == .listening ? listeningTint(for: frame) : nil
            )

            Canvas { ctx, size in
                let s = min(size.width, size.height)
                guard s > 0 else { return }

                let reactionPulse = frame.reaction.map { max(0, 1 - ($0.age / $0.reaction.duration)) } ?? 0
                let isPureMusic = frame.mood == .listening && reaction == nil
                let vibe = frame.musicVibe
                let audio = frame.musicMetrics

                var r = p.red, g = p.green, b = p.blue
                if reaction == .failed {
                    r = 1.0; g = 0.42; b = 0.42
                } else if reaction == .charged {
                    r = 0.36; g = 0.96; b = 0.56
                }
                let color = Color(red: r, green: g, blue: b)

                let blinking = reaction != .failed
                    && reaction != .poke
                    && FaceSaccade.isBlinking(at: t, mood: frame.mood)

                // Eyes stay completely grounded at spring-smoothed (cx, cy) — ZERO bobbing!
                let cx = size.width / 2 + p.lookX * s
                let cy = size.height * 0.42 + p.lookY * s
                let gap = s * (frame.mood == .strained ? 0.38 : 0.42)
                let strokeW = max(1.7, s * 0.032)

                // Draw Eyes with subtle 3D perspective when looking sideways (video 00:00–00:02!)
                let turnRatio = min(max(p.lookX / 0.18, -1), 1)

                for (index, side) in [-1.0, 1.0].enumerated() {
                    let ex = cx + CGFloat(side) * gap / 2
                    // Far eye narrows subtly when turning sideways for natural 3D depth.
                    let perspectiveW: CGFloat = 1.0 - max(0, CGFloat(side) * turnRatio) * 0.14
                    let perspectiveH: CGFloat = 1.0 - max(0, CGFloat(side) * turnRatio) * 0.06

                    let baseW = p.eyeW * s * 0.62 * perspectiveW
                    var baseH = p.eyeH * s * 0.62 * perspectiveH * (blinking ? 0.10 : 1)

                    if reaction == .curious {
                        baseH *= (index == 0 ? 0.72 : 1.18)
                    } else if reaction == .charged {
                        baseH *= 1.12
                    }

                    if reaction == .failed {
                        // Expressive > < eyes for failed runs.
                        var chevron = Path()
                        let hw = baseW * 0.52
                        let hh = max(4.5, s * 0.12)
                        if index == 0 {
                            chevron.move(to: CGPoint(x: ex - hw, y: cy - hh))
                            chevron.addLine(to: CGPoint(x: ex + hw, y: cy))
                            chevron.addLine(to: CGPoint(x: ex - hw, y: cy + hh))
                        } else {
                            chevron.move(to: CGPoint(x: ex + hw, y: cy - hh))
                            chevron.addLine(to: CGPoint(x: ex - hw, y: cy))
                            chevron.addLine(to: CGPoint(x: ex + hw, y: cy + hh))
                        }
                        ctx.stroke(
                            chevron,
                            with: .color(color),
                            style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
                        )
                    } else if reaction == .poke || (frame.mood == .done && reaction == nil) {
                        // Happy ^ ^ curved eyes when poked or agent finishes (`ok`).
                        var arc = Path()
                        let hw = baseW * 0.62
                        arc.move(to: CGPoint(x: ex - hw, y: cy + s * 0.05))
                        arc.addQuadCurve(
                            to: CGPoint(x: ex + hw, y: cy + s * 0.05),
                            control: CGPoint(x: ex, y: cy - s * 0.14)
                        )
                        ctx.stroke(
                            arc,
                            with: .color(color),
                            style: StrokeStyle(lineWidth: strokeW * 1.15, lineCap: .round)
                        )
                    } else {
                        // Draw tilted/expressive pill eye using GraphicsContext transform.
                        // Working/Rock tilts inward (\ /), Melancholy/Overheated tilts outward (/ \).
                        let angleDegrees = Double(p.tilt) * 14.0 * (index == 0 ? -1.0 : 1.0)
                        var eyeCtx = ctx
                        eyeCtx.translateBy(x: ex, y: cy)
                        if !blinking && abs(angleDegrees) > 0.3 {
                            eyeCtx.rotate(by: .degrees(angleDegrees))
                        }
                        let localRect = CGRect(x: -baseW / 2, y: -baseH / 2, width: baseW, height: baseH)
                        eyeCtx.fill(
                            Path(roundedRect: localRect, cornerRadius: min(baseW, baseH) / 2),
                            with: .color(color)
                        )

                        // Clean slanted eyelid trim for Rock (\ /) and Melancholy (/ \).
                        if !blinking && baseH > 8 && abs(p.tilt) > 0.45 && frame.mood != .working {
                            var lid = Path()
                            let cutH = baseH * 0.30 * abs(p.tilt)
                            let inwardDown = p.tilt > 0
                            if (index == 0 && inwardDown) || (index == 1 && !inwardDown) {
                                lid.move(to: CGPoint(x: localRect.minX - 2, y: localRect.minY - 2))
                                lid.addLine(to: CGPoint(x: localRect.maxX + 2, y: localRect.minY - 2))
                                lid.addLine(to: CGPoint(x: localRect.maxX + 2, y: localRect.minY + cutH))
                                lid.closeSubpath()
                            } else {
                                lid.move(to: CGPoint(x: localRect.minX - 2, y: localRect.minY - 2))
                                lid.addLine(to: CGPoint(x: localRect.maxX + 2, y: localRect.minY - 2))
                                lid.addLine(to: CGPoint(x: localRect.minX - 2, y: localRect.minY + cutH))
                                lid.closeSubpath()
                            }
                            eyeCtx.fill(lid, with: .color(.black))
                        }
                    }
                }

                // 1. Working Scribbling Nib Animation (exact signature motif from video 00:05–00:16!)
                if p.scribble > 0.05 && reaction != .failed {
                    drawScribblingNib(
                        in: &ctx,
                        cx: cx,
                        my: cy + s * 0.34,
                        scale: s,
                        t: t,
                        alpha: Double(p.scribble),
                        color: color
                    )
                }

                // 2. Genre-Adaptive Music Mouth (steady eyes, expressive mouth!)
                if isPureMusic {
                    switch vibe {
                    case .hype, .rock:
                        // Crisp 5-bar mini equalizer mouth dancing cleanly to the live FFT bands
                        // while the eyes remain 100% steady — expressive with zero motion sickness!
                        drawMiniEqualizerMouth(
                            in: &ctx,
                            cx: cx,
                            my: cy + s * 0.33,
                            scale: s,
                            bands: audio.bands,
                            color: color
                        )
                    case .groove, .chill:
                        let mw = s * (vibe == .chill ? 0.22 : 0.28)
                        let my = cy + s * 0.29
                        let depth = vibe == .chill ? 0.07 : 0.115
                        var smile = Path()
                        smile.move(to: CGPoint(x: cx - mw / 2, y: my))
                        smile.addQuadCurve(
                            to: CGPoint(x: cx + mw / 2, y: my),
                            control: CGPoint(x: cx, y: my + s * CGFloat(depth))
                        )
                        ctx.stroke(
                            smile,
                            with: .color(color.opacity(vibe == .chill ? 0.65 : 0.90)),
                            style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round)
                        )
                    case .melancholy:
                        let mw = s * 0.18
                        let my = cy + s * 0.32
                        var wistful = Path()
                        wistful.move(to: CGPoint(x: cx - mw / 2, y: my))
                        wistful.addQuadCurve(
                            to: CGPoint(x: cx + mw / 2, y: my),
                            control: CGPoint(x: cx, y: my - s * 0.028)
                        )
                        ctx.stroke(
                            wistful,
                            with: .color(color.opacity(0.65)),
                            style: StrokeStyle(lineWidth: max(1.4, s * 0.025), lineCap: .round)
                        )
                    }
                } else if reaction == .poke || reaction == .charged || (frame.mood == .done && reaction == nil) {
                    let strength = frame.mood == .done ? 1.0 : reactionPulse
                    let mw = s * 0.26
                    let my = cy + s * 0.28
                    var smile = Path()
                    smile.move(to: CGPoint(x: cx - mw / 2, y: my))
                    smile.addQuadCurve(
                        to: CGPoint(x: cx + mw / 2, y: my),
                        control: CGPoint(x: cx, y: my + s * 0.11 * CGFloat(strength))
                    )
                    ctx.stroke(
                        smile,
                        with: .color(color.opacity(strength)),
                        style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round)
                    )
                } else if reaction == .failed {
                    let mw = s * 0.20
                    let my = cy + s * 0.32
                    var frown = Path()
                    frown.move(to: CGPoint(x: cx - mw / 2, y: my))
                    frown.addQuadCurve(
                        to: CGPoint(x: cx + mw / 2, y: my),
                        control: CGPoint(x: cx, y: my - s * 0.07)
                    )
                    ctx.stroke(
                        frown,
                        with: .color(color.opacity(0.9)),
                        style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round)
                    )
                }

                // 3. Overheated micro-cue: single slow teardrop sweat bead beside right eye.
                if frame.mood == .overheated {
                    let phase = t.truncatingRemainder(dividingBy: 2.0) / 2.0
                    let dropX = cx + gap / 2 + s * 0.22
                    let dropY = cy - s * 0.14 + CGFloat(phase) * s * 0.24
                    let alpha = sin(phase * .pi)
                    let drop = CGRect(x: dropX - 2.2, y: dropY - 3.2, width: 4.4, height: 6.4)
                    ctx.fill(
                        Path(ellipseIn: drop),
                        with: .color(Color(red: 0.52, green: 0.86, blue: 1.0).opacity(alpha * 0.9))
                    )
                }

                // 4. Sleeping micro-cue: two calm drifting "z" specks (eyes stay completely still).
                if frame.mood == .sleep {
                    for idx in 0..<2 {
                        let phase = (t * 0.28 + Double(idx) * 0.5).truncatingRemainder(dividingBy: 1.0)
                        let zx = cx + gap * 0.60 + CGFloat(phase) * s * 0.10
                        let zy = cy - s * 0.10 - CGFloat(phase) * s * 0.20
                        let alpha = sin(phase * .pi) * 0.60
                        let zSize: CGFloat = idx == 0 ? 5.5 : 4.2
                        var zPath = Path()
                        zPath.move(to: CGPoint(x: zx - zSize / 2, y: zy - zSize / 2))
                        zPath.addLine(to: CGPoint(x: zx + zSize / 2, y: zy - zSize / 2))
                        zPath.addLine(to: CGPoint(x: zx - zSize / 2, y: zy + zSize / 2))
                        zPath.addLine(to: CGPoint(x: zx + zSize / 2, y: zy + zSize / 2))
                        ctx.stroke(
                            zPath,
                            with: .color(color.opacity(alpha)),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }
        }
    }

    /// Draws the signature writing/scribbling pen-nib leaving a crisp wavy ink trail
    /// from left to right (matching the reference video 00:05–00:16).
    private func drawScribblingNib(
        in ctx: inout GraphicsContext,
        cx: CGFloat,
        my: CGFloat,
        scale s: CGFloat,
        t: TimeInterval,
        alpha: Double,
        color: Color
    ) {
        let cycle = 2.6
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        // 0.00..0.75: scribble left -> right; 0.75..1.00: hold & fade cleanly before next stroke.
        let progress = min(1.0, phase / 0.75)
        let fade = phase < 0.75 ? 1.0 : max(0, 1.0 - (phase - 0.75) / 0.25)
        let strokeAlpha = alpha * fade

        let lineW = s * 0.44
        let startX = cx - lineW / 2
        let headX = startX + lineW * CGFloat(progress)
        let steps = max(2, Int(progress * 36))

        var trail = Path()
        for i in 0...steps {
            let u = Double(i) / 36.0
            let x = startX + lineW * CGFloat(u)
            let y = my + CGFloat(sin(u * .pi * 6.0)) * s * 0.026
            if i == 0 {
                trail.move(to: CGPoint(x: x, y: y))
            } else {
                trail.addLine(to: CGPoint(x: x, y: y))
            }
        }
        ctx.stroke(
            trail,
            with: .color(color.opacity(strokeAlpha * 0.85)),
            style: StrokeStyle(lineWidth: max(1.4, s * 0.024), lineCap: .round, lineJoin: .round)
        )

        // Tilted glowing stylus/nib droplet at the leading tip of the stroke.
        let headY = my + CGFloat(sin(progress * .pi * 6.0)) * s * 0.026
        var nibCtx = ctx
        nibCtx.translateBy(x: headX + s * 0.035, y: headY - s * 0.045)
        nibCtx.rotate(by: .degrees(32))
        let nibW = s * 0.075
        let nibH = s * 0.145
        let nibRect = CGRect(x: -nibW / 2, y: -nibH / 2, width: nibW, height: nibH)
        nibCtx.fill(
            Path(roundedRect: nibRect, cornerRadius: nibW / 2),
            with: .color(color.opacity(strokeAlpha))
        )
    }

    /// Draws a compact, grounded 5-bar equalizer mouth for Hype/Rock tracks
    /// so music feels alive while the eyes stay steady.
    private func drawMiniEqualizerMouth(
        in ctx: inout GraphicsContext,
        cx: CGFloat,
        my: CGFloat,
        scale s: CGFloat,
        bands: [Double],
        color: Color
    ) {
        let count = 5
        let barW = max(2.2, s * 0.036)
        let spacing = barW * 1.45
        let totalW = CGFloat(count - 1) * spacing
        let maxH = s * 0.16

        for i in 0..<count {
            let level = i < bands.count ? bands[i] : 0.2
            // Taper outer bars slightly so it forms a pleasing smile-like silhouette.
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

    private func listeningTint(for frame: AgentFaceFrameContext) -> (r: Double, g: Double, b: Double)? {
        if let albumTint = frame.musicTint {
            return albumTint
        }
        switch frame.musicVibe {
        case .chill:      return (0.86, 0.84, 0.98)
        case .groove:     return (0.82, 0.88, 1.00)
        case .hype:       return (0.96, 0.62, 0.96)
        case .rock:       return (1.00, 0.48, 0.44)
        case .melancholy: return (0.62, 0.76, 0.98)
        }
    }
}

// MARK: - Dropped Chin Container & Unified Mac Companion View

/// Full procedural face sitting in a dropped chin directly below the camera cutout.
struct AgentFaceDroppedChinView: View {
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    let meetingBadge: UpcomingMeetingCue?
    let trackCursor: Bool
    let onGazeChanged: (CGPoint?) -> Void
    let onMeetingTap: ((UpcomingMeetingCue) -> Void)?
    let contextProvider: (Date) -> AgentFaceFrameContext

    static let faceHeight: CGFloat = 72
    static let faceWidth: CGFloat = 132

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
            .overlay {
                FaceTrackingOverlay(enabled: trackCursor, onGazeChanged: onGazeChanged)
            }
        }
    }
}

/// Unified closed-notch Mac companion face reacting to Dev agents, Music,
/// Calendar, Notifications, System health, user activity, and cursor gaze.
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

    var body: some View {
        let now = Date()
        let meeting = reactToCalendar
            ? MacFaceInputs.upcomingMeeting(from: calendar.events, now: now)
            : nil

        AgentFaceDroppedChinView(
            cameraWidth: vm.closedNotchSize.width,
            cameraHeight: cameraHeight,
            meetingBadge: meeting,
            trackCursor: trackCursor,
            onGazeChanged: { point in
                gaze = point
                if point != nil {
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
                let (musicMetrics, musicVibe) = observer.sampleAudioMetrics(at: t, isPlaying: isVibing)
                let musicTint = resolvedMusicTint(isVibing: isVibing)
                let reaction = resolvedReaction(at: date)
                let activeDevActivity = devStore.items.first(where: { $0.status == .run })?.activity

                return AgentFaceFrameContext(
                    mood: mood,
                    reaction: reaction,
                    musicListening: isVibing,
                    musicVibe: musicVibe,
                    musicMetrics: musicMetrics,
                    musicTint: musicTint,
                    gaze: trackCursor ? gaze : nil,
                    isUserTyping: observer.isUserActivelyTyping(at: date),
                    appSwitchLookX: observer.appSwitchLookX(at: date),
                    devActivity: activeDevActivity
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
    var height: CGFloat = 72
    var width: CGFloat = 128
    var mood: AgentFaceMood = .idle

    var body: some View {
        AgentFaceCanvas(mood: mood)
            .frame(width: width, height: height)
    }
}

#Preview {
    ZStack {
        Color.black
        AnimatedFace(height: 72, width: 128, mood: .working)
    }
    .frame(width: 220, height: 110)
}
