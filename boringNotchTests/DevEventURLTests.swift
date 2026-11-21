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
}
