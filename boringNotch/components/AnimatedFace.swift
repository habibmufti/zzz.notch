//
//  AnimatedFace.swift
//  zzz.notch
//
//  Unified procedural Mac companion face rendered in a dropped chin below the
//  camera cutout. Reacts in real time to Dev agents, Music playback, upcoming
//  Calendar meetings, Notifications, event-driven System health signals
//  (thermal state, memory pressure, battery/charger), and cursor gaze — with
//  zero background polling.
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

    static let sleepyAfterSeconds: TimeInterval = 60
    static let sleepAfterSeconds: TimeInterval = 180

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

    static let silent = MusicAudioMetrics()

    /// Extracts bass (60–380 Hz), mid/vocal (380–2.5 kHz), and treble (2.5–16 kHz)
    /// from AudioCaptureManager's 6 log-spaced FFT bands.
    static func from(bars: [Float], previousBass: Double) -> MusicAudioMetrics {
        guard bars.count >= 6 else {
            let avg = bars.isEmpty ? 0 : Double(bars.reduce(0, +)) / Double(bars.count)
            return MusicAudioMetrics(bass: avg, mid: avg, treble: avg, overall: avg, bassPunch: 0)
        }
        let bass = Double(bars[0] + bars[1]) * 0.5
        let mid = Double(bars[2] + bars[3]) * 0.5
        let treble = Double(bars[4] + bars[5]) * 0.5
        let overall = (bass + mid + treble) / 3.0
        let punch = min(1, max(0, (bass - previousBass) * 3.8))
        return MusicAudioMetrics(
            bass: bass,
            mid: mid,
            treble: treble,
            overall: overall,
            bassPunch: punch
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
        // Specific mood/subgenre cues first so "lo-fi hip-hop" maps to chill
        // and "sad acoustic ballad" maps to melancholy before broader buckets.
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

    private(set) var activeReaction: AgentFaceReaction?
    private(set) var reactionAt = Date.distantPast

    private var thermalObserver: NSObjectProtocol?
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
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        memoryPressureSource?.cancel()
        if let powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerRunLoopSource, .commonModes)
        }
    }

    func noteActivity() {
        lastActivityAt = Date()
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
        // 1. Thermal state notifications (zero polling).
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

        // 2. Kernel memory pressure push source (zero polling).
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

        // 3. IOKit power source change callback (zero polling).
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

    private func installAppObservers() {
        // React to incoming notifications & dev failures.
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

        // Wake when dev sessions change.
        DevActivityStore.shared.$items
            .dropFirst()
            .sink { [weak self] _ in
                self?.lastActivityAt = Date()
            }
            .store(in: &cancellables)

        // Wake when music playback starts/stops & keep track genre synced.
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
            // Gentle synthetic beat pulse when Core Audio process tap is off.
            let beatSpeed: Double = {
                switch musicVibeFromMetadata {
                case .hype: return 2.35
                case .rock: return 2.5
                case .chill: return 1.2
                case .melancholy: return 0.95
                case .groove, .none: return 1.9
                }
            }()
            let pulse = max(0, sin(t * 2 * .pi * beatSpeed))
            let level = 0.25 + 0.45 * pulse
            metrics = MusicAudioMetrics(
                bass: level,
                mid: level * 0.85,
                treble: level * 0.6,
                overall: level,
                bassPunch: pulse > 0.82 ? (pulse - 0.82) * 3.5 : 0
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
                bassPunch: metrics.bassPunch
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

        // Immediate local heuristic pass (instant, works offline).
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
            // Short debounce so fast track skipping doesn't fire unnecessary lookups.
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

// MARK: - Procedural Pose & Spring Physics

/// Every pose is a small vector of normalized numbers; the canvas only draws these.
struct AgentFacePose: Equatable, Sendable {
    var eyeW: CGFloat
    var eyeH: CGFloat
    var lookX: CGFloat
    var lookY: CGFloat
    /// 0 hidden … 1 full wavy working mouth.
    var mouth: CGFloat
    /// Color blend weights (interpolated smoothly by the spring).
    var red: Double
    var green: Double
    var blue: Double
    /// 0 normal … 1 celebratory smile arc.
    var smile: Double

    static func target(_ mood: AgentFaceMood) -> AgentFacePose {
        switch mood {
        case .idle:
            AgentFacePose(eyeW: 0.30, eyeH: 0.70, lookX: 0, lookY: 0, mouth: 0, red: 0.80, green: 0.78, blue: 0.98, smile: 0)
        case .working:
            AgentFacePose(eyeW: 0.30, eyeH: 0.62, lookX: -0.12, lookY: -0.04, mouth: 1, red: 0.80, green: 0.78, blue: 0.98, smile: 0)
        case .waiting:
            AgentFacePose(eyeW: 0.34, eyeH: 0.85, lookX: 0, lookY: -0.10, mouth: 0, red: 1.00, green: 0.86, blue: 0.18, smile: 0)
        case .done:
            AgentFacePose(eyeW: 0.34, eyeH: 0.56, lookX: 0, lookY: -0.04, mouth: 0, red: 0.45, green: 0.94, blue: 0.65, smile: 1)
        case .listening:
            AgentFacePose(eyeW: 0.32, eyeH: 0.54, lookX: 0, lookY: -0.02, mouth: 0, red: 0.78, green: 0.82, blue: 1.00, smile: 0.65)
        case .meeting:
            AgentFacePose(eyeW: 0.33, eyeH: 0.78, lookX: 0, lookY: -0.08, mouth: 0, red: 0.42, green: 0.88, blue: 1.00, smile: 0)
        case .overheated:
            AgentFacePose(eyeW: 0.36, eyeH: 0.44, lookX: 0, lookY: 0.04, mouth: 0.45, red: 1.00, green: 0.52, blue: 0.28, smile: 0)
        case .strained:
            AgentFacePose(eyeW: 0.38, eyeH: 0.30, lookX: 0, lookY: 0.02, mouth: 0.65, red: 1.00, green: 0.76, blue: 0.30, smile: 0)
        case .lowBattery:
            AgentFacePose(eyeW: 0.40, eyeH: 0.22, lookX: 0, lookY: 0.10, mouth: 0, red: 0.96, green: 0.42, blue: 0.42, smile: 0)
        case .sleepy:
            AgentFacePose(eyeW: 0.42, eyeH: 0.16, lookX: 0, lookY: 0.10, mouth: 0, red: 0.76, green: 0.74, blue: 0.94, smile: 0)
        case .sleep:
            AgentFacePose(eyeW: 0.42, eyeH: 0.05, lookX: 0, lookY: 0.14, mouth: 0, red: 0.70, green: 0.68, blue: 0.88, smile: 0)
        }
    }
}

/// Critically damped spring following the target pose each frame.
/// Kept non-`@Published` so stepping inside `TimelineView` never triggers extra
/// SwiftUI body invalidations.
final class AgentFaceEngine: ObservableObject {
    private(set) var pose: AgentFacePose
    private var velocity = [CGFloat](repeating: 0, count: 9)
    private var lastTimestamp: TimeInterval?

    init(initialMood: AgentFaceMood = .idle) {
        self.pose = .target(initialMood)
    }

    func step(
        to mood: AgentFaceMood,
        at timestamp: TimeInterval,
        tintOverride: (r: Double, g: Double, b: Double)? = nil
    ) -> AgentFacePose {
        let dt: CGFloat
        if let last = lastTimestamp {
            dt = CGFloat(min(max(timestamp - last, 0), 1.0 / 30.0))
        } else {
            dt = 0
        }
        lastTimestamp = timestamp

        var target = AgentFacePose.target(mood)
        if let tint = tintOverride {
            target.red = target.red * 0.55 + tint.r * 0.45
            target.green = target.green * 0.55 + tint.g * 0.45
            target.blue = target.blue * 0.55 + tint.b * 0.45
        }

        var cur: [CGFloat] = [
            pose.eyeW, pose.eyeH, pose.lookX, pose.lookY, pose.mouth,
            CGFloat(pose.red), CGFloat(pose.green), CGFloat(pose.blue), CGFloat(pose.smile)
        ]
        let tgt: [CGFloat] = [
            target.eyeW, target.eyeH, target.lookX, target.lookY, target.mouth,
            CGFloat(target.red), CGFloat(target.green), CGFloat(target.blue), CGFloat(target.smile)
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
            red: Double(min(max(cur[5], 0), 1)),
            green: Double(min(max(cur[6], 0), 1)),
            blue: Double(min(max(cur[7], 0), 1)),
            smile: Double(min(max(cur[8], 0), 1))
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
            abs(CGFloat(pose.red - target.red)),
            abs(CGFloat(pose.green - target.green)),
            abs(CGFloat(pose.blue - target.blue)),
            abs(CGFloat(pose.smile - target.smile))
        ]
        let maxDiff = diffs.max() ?? 0
        let maxVel = velocity.map(abs).max() ?? 0
        return maxDiff < 0.006 && maxVel < 0.012
    }
}

// MARK: - Cursor Gaze & Poke Tracking

final class FaceTrackingNSView: NSView {
    var onGazeChanged: ((CGPoint?) -> Void)?
    var onPoke: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let expanded = bounds.insetBy(dx: -80, dy: -32)
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
        let nx = max(-1, min(1, ((loc.x / bounds.width) - 0.5) * 1.4))
        // NSView Y grows upward; SwiftUI Canvas Y grows downward.
        let ny = max(-1, min(1, (0.5 - (loc.y / bounds.height)) * 1.4))
        onGazeChanged?(CGPoint(x: nx, y: ny))
    }

    override func mouseExited(with event: NSEvent) {
        onGazeChanged?(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Stay transparent to clicks so ContentView tap/drag/hover work normally.
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
        if ctx.reaction != nil || ctx.gaze != nil || !engine.isSettled(for: ctx.mood) {
            return 1.0 / 30.0
        }
        switch ctx.mood {
        case .working, .waiting, .done, .listening, .meeting, .overheated, .strained:
            return 1.0 / 30.0
        case .idle, .sleepy, .lowBattery:
            return 1.0 / 20.0
        case .sleep:
            return 1.0 / 6.0
        }
    }

    var body: some View {
        let probe = contextProvider(Date())
        TimelineView(.animation(minimumInterval: frameInterval(for: probe))) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let frame = contextProvider(now)
            let p = engine.step(
                to: frame.mood,
                at: t,
                tintOverride: frame.mood == .listening ? listeningTint(for: frame) : nil
            )

            Canvas { ctx, size in
                let s = min(size.width, size.height)
                guard s > 0 else { return }

                let reaction = frame.reaction?.reaction
                let reactionAge = frame.reaction?.age ?? 0
                let reactionPulse = frame.reaction.map { max(0, 1 - ($0.age / $0.reaction.duration)) } ?? 0
                let isPureMusic = frame.mood == .listening && reaction == nil
                let vibe = frame.musicVibe
                let audio = frame.musicMetrics

                // Resolve effective color (reactions temporarily override tint).
                var r = p.red, g = p.green, b = p.blue
                if reaction == .failed {
                    r = 1.0; g = 0.42; b = 0.42
                } else if reaction == .charged {
                    r = 0.36; g = 0.96; b = 0.56
                }
                let color = Color(red: r, green: g, blue: b)

                // Micro-motion: blink, glance, genre-adaptive music rhythm, sleep breath, cursor gaze.
                let blinkCycle: Double = (isPureMusic && vibe == .chill) ? 4.4 : 3.3
                let blinking = frame.mood != .sleep
                    && frame.mood != .sleepy
                    && reaction != .failed
                    && reaction != .poke
                    && t.truncatingRemainder(dividingBy: blinkCycle) < 0.13

                let glance: CGFloat = {
                    if let gaze = frame.gaze {
                        return gaze.x * 0.14
                    }
                    if reaction == .trackSkip {
                        return CGFloat(sin(min(reactionAge * 5, .pi)) * 0.18)
                    }
                    switch frame.mood {
                    case .working:
                        let speed = frame.devActivity == "search" ? 2.6 : 1.7
                        let amp = frame.devActivity == "search" ? 0.14 : 0.10
                        return CGFloat(sin(t * speed) * amp)
                    case .listening:
                        switch vibe {
                        case .chill:
                            return CGFloat(sin(t * 1.05) * 0.055)
                        case .melancholy:
                            return CGFloat(sin(t * 0.8) * 0.03)
                        case .groove:
                            return CGFloat(sin(t * 2.2) * 0.075)
                        case .hype:
                            return CGFloat(sin(t * 3.1) * (0.05 + audio.bass * 0.05))
                        case .rock:
                            return CGFloat(sin(t * 3.8) * 0.04)
                        }
                    case .meeting:
                        return CGFloat(sin(t * 2.0) * 0.05)
                    case .sleep:
                        return 0
                    default:
                        return CGFloat(sin(t * 0.6) * 0.02)
                    }
                }()

                let gazeY: CGFloat = frame.gaze.map { $0.y * 0.08 } ?? 0
                let musicBobY: CGFloat = {
                    guard frame.musicListening else { return 0 }
                    let scale: Double = frame.mood == .listening ? 1.0 : 0.45
                    switch vibe {
                    case .chill:
                        return CGFloat(sin(t * 1.4) * 0.025 * scale)
                    case .melancholy:
                        return CGFloat((0.03 + sin(t * 0.9) * 0.015) * scale)
                    case .groove:
                        return CGFloat(-(audio.overall * 0.065 + audio.bassPunch * 0.05) * scale)
                    case .hype:
                        return CGFloat(-(audio.bass * 0.075 + audio.bassPunch * 0.095) * scale)
                    case .rock:
                        // Strong downward headbang accent on kick/treble hits.
                        let bang = (audio.bassPunch * 0.12) + (audio.treble * 0.05)
                        return CGFloat((bang - audio.overall * 0.04) * scale)
                    }
                }()
                let reactionBobY: CGFloat = (reaction == .poke || reaction == .charged || reaction == .trackChange)
                    ? CGFloat(-abs(sin(reactionAge * 8)) * 0.07 * reactionPulse)
                    : 0
                let breathY: CGFloat = frame.mood == .sleep
                    ? CGFloat(sin(t * 1.1) * 0.018)
                    : 0

                let cx = size.width / 2 + (p.lookX + glance) * s
                let cy = size.height * 0.42 + (p.lookY + gazeY + musicBobY + reactionBobY + breathY) * s
                let gap = s * (frame.mood == .strained ? 0.34 : 0.38)
                let strokeW = max(1.6, s * 0.032)

                // Draw Eyes
                for (index, side) in [-1.0, 1.0].enumerated() {
                    let ex = cx + CGFloat(side) * gap / 2
                    var baseW = p.eyeW * s * 0.62
                    var baseH = p.eyeH * s * 0.62 * (blinking ? 0.12 : 1)

                    // Genre-adaptive eye squash/stretch & lid proportions while listening.
                    if isPureMusic && !blinking {
                        switch vibe {
                        case .chill:
                            baseH *= 0.62
                            baseW *= 1.08
                        case .melancholy:
                            baseH *= 0.88
                        case .groove:
                            baseH *= CGFloat(1.0 + audio.bassPunch * 0.14)
                        case .hype:
                            // Snappy squash-and-stretch on bass kicks.
                            baseW *= CGFloat(1.0 + audio.bassPunch * 0.22)
                            baseH *= CGFloat(1.05 + audio.bass * 0.22 - audio.bassPunch * 0.10)
                        case .rock:
                            baseH *= CGFloat(0.92 + audio.bassPunch * 0.18)
                            baseW *= 1.06
                        }
                    }

                    // Curious notification glance: asymmetric eyebrow/eye height (o O).
                    if reaction == .curious {
                        baseH *= (index == 0 ? 0.78 : 1.18)
                    } else if reaction == .charged {
                        baseH *= 1.12
                    }

                    if reaction == .failed {
                        // Expressive > < eyes for failed runs.
                        var chevron = Path()
                        let hw = baseW * 0.55
                        let hh = max(4, s * 0.12)
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
                    } else if reaction == .poke {
                        // Happy ^ ^ curved eyes when poked.
                        var arc = Path()
                        let hw = baseW * 0.65
                        arc.move(to: CGPoint(x: ex - hw, y: cy + s * 0.04))
                        arc.addQuadCurve(
                            to: CGPoint(x: ex + hw, y: cy + s * 0.04),
                            control: CGPoint(x: ex, y: cy - s * 0.14)
                        )
                        ctx.stroke(
                            arc,
                            with: .color(color),
                            style: StrokeStyle(lineWidth: strokeW, lineCap: .round)
                        )
                    } else {
                        let rect = CGRect(x: ex - baseW / 2, y: cy - baseH / 2, width: baseW, height: baseH)
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: min(baseW, baseH) / 2),
                            with: .color(color)
                        )

                        // Minimalist eyelid corner masks on black background for Rock (\ /) & Melancholy (/ \).
                        if isPureMusic && !blinking && baseH > 6 {
                            if vibe == .rock {
                                var lid = Path()
                                let cutH = baseH * 0.36
                                if index == 0 {
                                    // Left eye: slant down toward center (\)
                                    lid.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY + cutH))
                                    lid.closeSubpath()
                                } else {
                                    // Right eye: slant down toward center (/)
                                    lid.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.minX - 1, y: rect.minY + cutH))
                                    lid.closeSubpath()
                                }
                                ctx.fill(lid, with: .color(.black))
                            } else if vibe == .melancholy {
                                var lid = Path()
                                let cutH = baseH * 0.32
                                if index == 0 {
                                    // Left eye: outer top edge softens downward (/)
                                    lid.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.minX - 1, y: rect.minY + cutH))
                                    lid.closeSubpath()
                                } else {
                                    // Right eye: outer top edge softens downward (\)
                                    lid.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY - 1))
                                    lid.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY + cutH))
                                    lid.closeSubpath()
                                }
                                ctx.fill(lid, with: .color(.black))
                            }
                        }
                    }
                }

                // Mouth rendering: working wave, hype/rock singing wave, melancholy quiet line, or happy smile.
                let musicWaveStrength: CGFloat = (isPureMusic && (vibe == .hype || vibe == .rock))
                    ? CGFloat(min(1, max(0.25, audio.mid * 1.15 + audio.bassPunch * 0.45)))
                    : 0
                let effectiveWave = max(p.mouth, musicWaveStrength)

                if effectiveWave > 0.02 && reaction != .failed {
                    var path = Path()
                    let mw = s * (isPureMusic && vibe == .rock ? 0.36 : 0.34)
                    let my = cy + s * 0.32
                    let waveSpeed: Double = {
                        if isPureMusic && vibe == .hype { return 11.0 }
                        if isPureMusic && vibe == .rock { return 13.0 }
                        if frame.mood == .strained { return 10.0 }
                        return 7.0
                    }()
                    let ampScale: CGFloat = isPureMusic ? (0.020 + CGFloat(audio.mid) * 0.028) : 0.025
                    for i in 0...40 {
                        let x = cx - mw / 2 + mw * CGFloat(i) / 40
                        let y = my + sin(Double(i) / 40 * .pi * 4 - t * waveSpeed) * s * ampScale * effectiveWave
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    ctx.stroke(
                        path,
                        with: .color(color.opacity(Double(effectiveWave))),
                        style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round, lineJoin: .round)
                    )
                } else if isPureMusic && vibe == .melancholy {
                    // Subtle wistful slightly-curved mouth for ballads/melancholy tracks.
                    let mw = s * 0.20
                    let my = cy + s * 0.31
                    var soft = Path()
                    soft.move(to: CGPoint(x: cx - mw / 2, y: my))
                    soft.addQuadCurve(
                        to: CGPoint(x: cx + mw / 2, y: my),
                        control: CGPoint(x: cx, y: my - s * 0.03)
                    )
                    ctx.stroke(
                        soft,
                        with: .color(color.opacity(0.65)),
                        style: StrokeStyle(lineWidth: max(1.4, s * 0.025), lineCap: .round)
                    )
                }

                // Happy smile arc for done, chill/groove music, charged, or poke.
                let musicSmile: Double = (isPureMusic && (vibe == .groove || vibe == .chill))
                    ? (vibe == .groove ? 0.85 : 0.55)
                    : 0
                let smileStrength = max(
                    frame.mood == .listening ? musicSmile : p.smile,
                    (reaction == .poke || reaction == .charged) ? reactionPulse : 0
                )
                if smileStrength > 0.05 && effectiveWave < 0.25 && reaction != .failed && !(isPureMusic && vibe == .melancholy) {
                    let mw = s * (vibe == .chill && isPureMusic ? 0.22 : 0.27)
                    let my = cy + s * 0.28
                    let depth = (vibe == .chill && isPureMusic) ? 0.075 : 0.115
                    var smile = Path()
                    smile.move(to: CGPoint(x: cx - mw / 2, y: my))
                    smile.addQuadCurve(
                        to: CGPoint(x: cx + mw / 2, y: my),
                        control: CGPoint(x: cx, y: my + s * CGFloat(depth * smileStrength))
                    )
                    ctx.stroke(
                        smile,
                        with: .color(color.opacity(smileStrength)),
                        style: StrokeStyle(lineWidth: max(1.5, s * 0.028), lineCap: .round)
                    )
                }

                // Overheated micro-cue: subtle animated sweat drop beside right eye.
                if frame.mood == .overheated {
                    let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let dropX = cx + gap / 2 + s * 0.20
                    let dropY = cy - s * 0.16 + CGFloat(phase) * s * 0.26
                    let alpha = sin(phase * .pi)
                    let drop = CGRect(x: dropX - 2.2, y: dropY - 3.2, width: 4.4, height: 6.4)
                    ctx.fill(
                        Path(ellipseIn: drop),
                        with: .color(Color(red: 0.52, green: 0.86, blue: 1.0).opacity(alpha * 0.9))
                    )
                }

                // Sleeping micro-cue: two tiny drifting "z" specks rising gently.
                if frame.mood == .sleep {
                    for idx in 0..<2 {
                        let phase = (t * 0.35 + Double(idx) * 0.5).truncatingRemainder(dividingBy: 1.0)
                        let zx = cx + gap * 0.58 + CGFloat(phase) * s * 0.12
                        let zy = cy - s * 0.10 - CGFloat(phase) * s * 0.22
                        let alpha = sin(phase * .pi) * 0.65
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

    private func listeningTint(for frame: AgentFaceFrameContext) -> (r: Double, g: Double, b: Double)? {
        if let albumTint = frame.musicTint {
            return albumTint
        }
        switch frame.musicVibe {
        case .chill:      return (0.86, 0.82, 0.98)
        case .groove:     return (0.78, 0.86, 1.00)
        case .hype:       return (0.98, 0.56, 0.94)
        case .rock:       return (1.00, 0.48, 0.44)
        case .melancholy: return (0.58, 0.72, 0.98)
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
                                .fill(Color(red: 0.42, green: 0.88, blue: 1.0))
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
/// Calendar, Notifications, System health, and cursor gaze.
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
        // Keep the tint pastel & bright so the eyes stay crisp on pure black.
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
