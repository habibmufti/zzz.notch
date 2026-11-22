//
//  NotificationPanelDetectionTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

final class NotificationPanelDetectionTests: XCTestCase {
    func testPanelSubroleIsPanelMarker() {
        XCTAssertTrue(NotificationPanelDetection.isPanel(
            subrole: "AXNotificationCenterPanel",
            identifier: nil
        ))
    }

    func testWidgetEditorIsPanelMarker() {
        XCTAssertTrue(NotificationPanelDetection.isPanel(
            subrole: "AXButton",
            identifier: "widget-editor-button"
        ))
    }

    func testDesktopWidgetIsNotALiveBanner() {
        XCTAssertTrue(NotificationPanelDetection.isDesktopWidget(identifier: "widget-local:calendar"))
        XCTAssertFalse(NotificationPanelDetection.isDesktopWidget(identifier: "notification-id"))
    }

    func testListIdentifierDoesNotImplyPanel() {
        XCTAssertFalse(NotificationPanelDetection.isPanel(
            subrole: "AXScrollArea",
            identifier: NotificationPanelDetection.panelListIdentifier
        ))
    }

    func testStackButtonIsPanelOnlyInsideNotificationList() {
        XCTAssertTrue(NotificationPanelDetection.isPanel(
            subrole: "AXButton",
            identifier: nil,
            stackingIdentifier: "stack-notification-id",
            insideNotificationList: true
        ))
        XCTAssertFalse(NotificationPanelDetection.isPanel(
            subrole: "AXButton",
            identifier: nil,
            stackingIdentifier: "stack-notification-id",
            insideNotificationList: false
        ))
    }

    func testKnownBannerSubrolesAreNotPanelMarkers() {
        for subrole in NotificationPanelDetection.bannerSubroles {
            XCTAssertTrue(NotificationPanelDetection.isBanner(subrole: subrole))
            XCTAssertFalse(NotificationPanelDetection.isPanel(subrole: subrole, identifier: nil))
        }
    }

    func testStackedLiveAlertIsIncluded() {
        XCTAssertTrue(NotificationPanelDetection.isBanner(subrole: "AXNotificationCenterAlertStack"))
    }

    func testObservationPolicyIncludesStructuralEvents() {
        for notification in [
            "AXWindowCreated",
            "AXCreated",
            "AXUIElementDestroyed",
            "AXChildrenChanged",
            "AXLayoutChanged"
        ] {
            XCTAssertTrue(
                NotificationObservationPolicy.shouldScan(notification: notification),
                notification
            )
        }
    }

    func testObservationPolicySkipsNonStructuralEvents() {
        for notification in [
            "AXWindowMoved",
            "AXWindowResized",
            "AXValueChanged",
            "AXTitleChanged",
            "AXSelectedChildrenChanged",
            "AXFocusedUIElementChanged"
        ] {
            XCTAssertFalse(
                NotificationObservationPolicy.shouldScan(notification: notification),
                notification
            )
        }
    }

    func testObservationPolicySkipsPanelAndDesktopWidgetEvents() {
        XCTAssertFalse(NotificationObservationPolicy.shouldScan(
            notification: "AXLayoutChanged",
            subrole: "AXNotificationCenterPanel"
        ))
        XCTAssertFalse(NotificationObservationPolicy.shouldScan(
            notification: "AXLayoutChanged",
            identifier: "widget-editor-button"
        ))
        XCTAssertFalse(NotificationObservationPolicy.shouldScan(
            notification: "AXLayoutChanged",
            identifier: "widget-local:weather"
        ))
        XCTAssertFalse(NotificationObservationPolicy.shouldObserveElement(
            subrole: "AXNotificationCenterPanel",
            identifier: nil
        ))
        XCTAssertTrue(NotificationObservationPolicy.shouldScan(
            notification: "AXWindowCreated",
            subrole: "AXNotificationCenterPanel"
        ))
    }

    func testActivateActionPrefersPressThenFallbacks() {
        XCTAssertEqual(
            NotificationActionSelection.activateAction(from: ["AXShowDefaultUI", "AXPress", "AXCancel"]),
            "AXPress"
        )
        XCTAssertEqual(
            NotificationActionSelection.activateAction(from: ["AXShowDefaultUI", "AXCancel"]),
            "AXShowDefaultUI"
        )
        XCTAssertEqual(
            NotificationActionSelection.activateAction(from: ["AXConfirm"]),
            "AXConfirm"
        )
        XCTAssertNil(
            NotificationActionSelection.activateAction(from: ["AXCancel", "Name:Close\nTarget:0x1"])
        )
    }

    func testDismissActionFindsCancelOrCustomCloseClearAction() {
        XCTAssertEqual(
            NotificationActionSelection.dismissAction(from: ["AXPress", "AXCancel"]),
            "AXCancel"
        )
        XCTAssertEqual(
            NotificationActionSelection.dismissAction(from: ["AXPress", "Name:Close\nTarget:0x1\nSelector:close:"]),
            "Name:Close\nTarget:0x1\nSelector:close:"
        )
        XCTAssertEqual(
            NotificationActionSelection.dismissAction(from: ["AXPress", "Name:Clear\nTarget:0x2"]),
            "Name:Clear\nTarget:0x2"
        )
        XCTAssertNil(
            NotificationActionSelection.dismissAction(from: ["AXPress", "Name:Reply\nTarget:0x3"])
        )
    }

    func testCloseOrOptionsControlDetection() {
        XCTAssertTrue(NotificationActionSelection.isCloseOrOptionsControl(subrole: "AXCloseButton", identifier: nil))
        XCTAssertTrue(NotificationActionSelection.isCloseOrOptionsControl(subrole: "AXButton", identifier: "options-button"))
        XCTAssertFalse(NotificationActionSelection.isCloseOrOptionsControl(subrole: "AXButton", identifier: "notification-body"))
    }
}
