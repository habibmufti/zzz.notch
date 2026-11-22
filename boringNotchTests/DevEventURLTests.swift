//
//  DevEventURLTests.swift
//  zzz.notch
//

import XCTest
@testable import boringNotch

final class DevEventURLTests: XCTestCase {
    func testParsesFullEvent() throws {
        let url = try XCTUnwrap(URL(string:
            "zzznotch://notify?title=Build%20failed&body=exit%201&source=make&status=FAIL"
            + "&symbol=hammer&app=com.mitchellh.ghostty&url=https%3A%2F%2Fexample.com%2Frun%3Fid%3D1"
            + "&id=build&duration=30"))
        let event = try XCTUnwrap(DevEventURL.notification(from: url))

        XCTAssertEqual(event.id, "dev-build")
        XCTAssertEqual(event.title, "Build failed")
        XCTAssertEqual(event.body, "exit 1")
        XCTAssertEqual(event.appName, "make")
        XCTAssertEqual(event.status, .fail)
        XCTAssertEqual(event.symbol, "hammer")
        XCTAssertEqual(event.bundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(event.actionURL?.absoluteString, "https://example.com/run?id=1")
        XCTAssertEqual(event.displayDuration, 30)
    }

    func testRejectsForeignOrEmptyURLs() throws {
        XCTAssertNil(DevEventURL.notification(from: try XCTUnwrap(URL(string: "zzznotch://notify?status=ok"))))
        XCTAssertNil(DevEventURL.notification(from: try XCTUnwrap(URL(string: "zzznotch://other?title=x"))))
        XCTAssertNil(DevEventURL.notification(from: try XCTUnwrap(URL(string: "https://notify?title=x"))))
    }

    func testDefaultsAndClamping() throws {
        let url = try XCTUnwrap(URL(string: "zzznotch://notify?title=hi&status=bogus&duration=99999"))
        let event = try XCTUnwrap(DevEventURL.notification(from: url))

        XCTAssertTrue(event.id.hasPrefix("dev-"))
        XCTAssertEqual(event.appName, "zzz")
        XCTAssertEqual(event.status, .info)
        XCTAssertEqual(event.displayDuration, 86_400)
        XCTAssertNil(event.actionURL)
    }

    func testClearURL() throws {
        XCTAssertEqual(DevEventURL.clearedID(from: try XCTUnwrap(URL(string: "zzznotch://clear?id=omp-1"))), "dev-omp-1")
        XCTAssertNil(DevEventURL.clearedID(from: try XCTUnwrap(URL(string: "zzznotch://clear"))))
    }

    func testCleanTitleStripsDecorativePrefixes() {
        XCTAssertEqual(DevText.cleanTitle("⟲RECAP: Recap yesterday's cashier progress"), "RECAP: Recap yesterday's cashier progress")
        XCTAssertEqual(DevText.cleanTitle("\u{E0B0} zzz.notch"), "zzz.notch")
        XCTAssertEqual(DevText.cleanTitle("plain title"), "plain title")
    }

    func testParseStepSeparatesToolAndShortensDeepPath() {
        let parsed = DevText.parseStep("edit: /private/tmp/wt-audit/docs/qa/2026-11-22-audit.md")
        XCTAssertEqual(parsed.tool, "edit")
        XCTAssertEqual(parsed.text, "…/docs/qa/2026-11-22-audit.md")

        let plain = DevText.parseStep("running tests")
        XCTAssertNil(plain.tool)
        XCTAssertEqual(plain.text, "running tests")
    }

    func testParsesPidContextAndTmux() throws {
        let url = try XCTUnwrap(URL(string: "zzznotch://notify?title=proj&status=run&pid=4242&context=142&tmux=%253"))
        let event = try XCTUnwrap(DevEventURL.notification(from: url))

        XCTAssertEqual(event.pid, 4242)
        XCTAssertEqual(event.contextPercent, 100)
        XCTAssertEqual(event.tmuxPane, "%3")

        let badPid = try XCTUnwrap(URL(string: "zzznotch://notify?title=proj&pid=0&context=-5"))
        let event2 = try XCTUnwrap(DevEventURL.notification(from: badPid))
        XCTAssertNil(event2.pid)
        XCTAssertEqual(event2.contextPercent, 0)
    }

    func testAgentFaceMoodPrioritizesWaitingThenWorkingThenDoneThenIdleProgression() {
        let now = Date()
        let run = SystemNotification(
            id: "dev-run",
            appName: "omp",
            bundleID: nil,
            title: "Task",
            subtitle: nil,
            body: nil,
            receivedAt: now,
            status: .run
        )
        let wait = SystemNotification(
            id: "dev-wait",
            appName: "omp",
            bundleID: nil,
            title: "Question",
            subtitle: nil,
            body: nil,
            receivedAt: now,
            status: .wait
        )
        let freshIdle = SystemNotification(
            id: "dev-idle",
            appName: "omp",
            bundleID: nil,
            title: "Idle",
            subtitle: nil,
            body: nil,
            receivedAt: now.addingTimeInterval(-10),
            status: .idle
        )
        let sleepyIdle = SystemNotification(
            id: "dev-sleepy",
            appName: "omp",
            bundleID: nil,
            title: "Sleepy",
            subtitle: nil,
            body: nil,
            receivedAt: now.addingTimeInterval(-25),
            status: .idle
        )
        let sleepingIdle = SystemNotification(
            id: "dev-sleep",
            appName: "omp",
            bundleID: nil,
            title: "Sleep",
            subtitle: nil,
            body: nil,
            receivedAt: now.addingTimeInterval(-60),
            status: .idle
        )

        XCTAssertEqual(AgentFaceMood.resolve(items: [run, wait], celebratingUntil: [:], now: now), .waiting)
        XCTAssertEqual(AgentFaceMood.resolve(items: [freshIdle, run], celebratingUntil: [:], now: now), .working)
        XCTAssertEqual(
            AgentFaceMood.resolve(
                items: [freshIdle],
                celebratingUntil: [freshIdle.id: now.addingTimeInterval(3)],
                now: now
            ),
            .done
        )
        XCTAssertEqual(AgentFaceMood.resolve(items: [freshIdle], celebratingUntil: [:], now: now), .idle)
        XCTAssertEqual(AgentFaceMood.resolve(items: [sleepyIdle], celebratingUntil: [:], now: now), .sleepy)
        XCTAssertEqual(AgentFaceMood.resolve(items: [sleepingIdle], celebratingUntil: [:], now: now), .sleep)
    }

    func testAgentFaceEngineConvergesToTargetPose() {
        let engine = AgentFaceEngine(initialMood: .idle)
        var t: TimeInterval = 0
        for _ in 0..<90 {
            t += 1.0 / 30.0
            _ = engine.step(to: .working, at: t)
        }
        let target = AgentFacePose.target(.working)
        XCTAssertEqual(engine.pose.eyeH, target.eyeH, accuracy: 0.01)
        XCTAssertEqual(engine.pose.scribble, target.scribble, accuracy: 0.01)
        XCTAssertEqual(engine.pose.tilt, target.tilt, accuracy: 0.01)
        XCTAssertTrue(engine.isSettled(for: .working))
    }

    func testMacFaceInputsResolvesCrossModulePriorityOrder() {
        let now = Date()
        let run = SystemNotification(
            id: "dev-run",
            appName: "omp",
            bundleID: nil,
            title: "Build",
            subtitle: nil,
            body: nil,
            receivedAt: now,
            status: .run
        )
        let wait = SystemNotification(
            id: "dev-wait",
            appName: "omp",
            bundleID: nil,
            title: "Question",
            subtitle: nil,
            body: nil,
            receivedAt: now,
            status: .wait
        )
        let meeting = UpcomingMeetingCue(title: "Standup", minutesUntilStart: 3, joinURL: nil)

        func makeInputs(
            devItems: [SystemNotification] = [],
            isMusicPlaying: Bool = false,
            upcomingMeeting: UpcomingMeetingCue? = nil,
            thermalState: SystemThermalState = .nominal,
            isMemoryPressured: Bool = false,
            batteryPercentage: Int? = 80,
            isCharging: Bool = false,
            lastActivityAt: Date = now
        ) -> MacFaceInputs {
            MacFaceInputs(
                devItems: devItems,
                celebratingUntil: [:],
                isMusicPlaying: isMusicPlaying,
                reactToMusic: true,
                upcomingMeeting: upcomingMeeting,
                reactToCalendar: true,
                thermalState: thermalState,
                isMemoryPressured: isMemoryPressured,
                batteryPercentage: batteryPercentage,
                isCharging: isCharging,
                isPluggedIn: isCharging,
                reactToSystem: true,
                lastActivityAt: lastActivityAt,
                now: now
            )
        }

        // 1. Waiting beats meeting & thermal.
        XCTAssertEqual(
            makeInputs(devItems: [wait], upcomingMeeting: meeting, thermalState: .critical).resolveMood(),
            .waiting
        )
        // 2. Imminent meeting beats system alerts & working.
        XCTAssertEqual(
            makeInputs(devItems: [run], upcomingMeeting: meeting, thermalState: .serious).resolveMood(),
            .meeting
        )
        // 3. System alerts: overheated > strained > lowBattery > working.
        XCTAssertEqual(
            makeInputs(devItems: [run], thermalState: .serious, isMemoryPressured: true, batteryPercentage: 10).resolveMood(),
            .overheated
        )
        XCTAssertEqual(
            makeInputs(devItems: [run], isMemoryPressured: true, batteryPercentage: 10).resolveMood(),
            .strained
        )
        XCTAssertEqual(
            makeInputs(devItems: [run], batteryPercentage: 12, isCharging: false).resolveMood(),
            .lowBattery
        )
        // Charging clears low-battery state -> falls through to working.
        XCTAssertEqual(
            makeInputs(devItems: [run], batteryPercentage: 12, isCharging: true).resolveMood(),
            .working
        )
        // 4. Music listening when no agent/alert.
        XCTAssertEqual(
            makeInputs(isMusicPlaying: true).resolveMood(),
            .listening
        )
        // 5. Idle progression -> sleepy (20s) -> sleep (45s).
        XCTAssertEqual(makeInputs(lastActivityAt: now.addingTimeInterval(-10)).resolveMood(), .idle)
        XCTAssertEqual(makeInputs(lastActivityAt: now.addingTimeInterval(-25)).resolveMood(), .sleepy)
        XCTAssertEqual(makeInputs(lastActivityAt: now.addingTimeInterval(-60)).resolveMood(), .sleep)
    }

    func testMusicVibeClassifierMapsGenresAndKeywords() {
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Hip-Hop/Rap"), .hype)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Electronic"), .hype)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Heavy Metal"), .rock)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Alternative"), .rock)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Jazz"), .chill)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Classical"), .chill)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Pop"), .groove)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "R&B/Soul"), .groove)
        XCTAssertEqual(MusicVibeClassifier.classify(genre: "Singer/Songwriter"), .melancholy)
        // Keyword heuristics work even without genre metadata.
        XCTAssertEqual(
            MusicVibeClassifier.classify(genre: nil, title: "Late Night Lo-Fi Study Beats", artist: "ChilledCow"),
            .chill
        )
        XCTAssertEqual(
            MusicVibeClassifier.classify(genre: nil, title: "Drift Phonk", artist: "DJ"),
            .hype
        )
        XCTAssertNil(MusicVibeClassifier.classify(genre: nil, title: "Track 01", artist: "Unknown"))
    }

    func testMusicAudioMetricsExtractsBandsPunchAndInferredVibe() {
        let bassHeavy = MusicAudioMetrics.from(bars: [0.85, 0.75, 0.45, 0.40, 0.30, 0.25], previousBass: 0.25)
        XCTAssertEqual(bassHeavy.bass, 0.80, accuracy: 0.001)
        XCTAssertGreaterThan(bassHeavy.bassPunch, 0.5)
        XCTAssertEqual(bassHeavy.inferredVibe(), .hype)

        let rockBright = MusicAudioMetrics.from(bars: [0.35, 0.40, 0.50, 0.50, 0.72, 0.68], previousBass: 0.35)
        XCTAssertEqual(rockBright.inferredVibe(), .rock)

        let quietChill = MusicAudioMetrics.from(bars: [0.15, 0.12, 0.18, 0.16, 0.10, 0.08], previousBass: 0.14)
        XCTAssertEqual(quietChill.inferredVibe(), .chill)
    }
}
