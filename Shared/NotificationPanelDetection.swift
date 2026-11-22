//
//  NotificationPanelDetection.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

enum NotificationPanelDetection {
    static let panelListIdentifier = "AXNotificationListItems"
    static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterAlert",
        "AXNotificationCenterNotification",
        "AXNotificationCenterBannerWindow",
        "AXNotificationCenterAlertStack"
    ]

    static func isPanel(
        subrole: String?,
        identifier: String?,
        stackingIdentifier: String? = nil,
        insideNotificationList: Bool = false
    ) -> Bool {
        subrole == "AXNotificationCenterPanel"
            || identifier == "widget-editor-button"
            || (insideNotificationList
                && subrole == "AXButton"
                && stackingIdentifier?.hasPrefix("stack-") == true)
    }

    static func isDesktopWidget(identifier: String?) -> Bool {
        identifier?.hasPrefix("widget-local:") == true
    }

    static func isBanner(subrole: String?) -> Bool {
        bannerSubroles.contains(subrole ?? "")
    }
}

enum NotificationObservationPolicy {
    static let structuralNotifications: Set<String> = [
        "AXWindowCreated",
        "AXCreated",
        "AXUIElementDestroyed",
        "AXChildrenChanged",
        "AXLayoutChanged"
    ]

    static func shouldObserveElement(subrole: String?, identifier: String?) -> Bool {
        !NotificationPanelDetection.isPanel(subrole: subrole, identifier: identifier)
            && !NotificationPanelDetection.isDesktopWidget(identifier: identifier)
    }

    static func shouldScan(
        notification: String,
        subrole: String? = nil,
        identifier: String? = nil
    ) -> Bool {
        guard structuralNotifications.contains(notification) else { return false }
        if notification == "AXWindowCreated" { return true }
        return shouldObserveElement(subrole: subrole, identifier: identifier)
    }
}

enum NotificationActionSelection {
    private static let preferredActivateActions = [
        "AXPress",
        "AXShowDefaultUI",
        "AXConfirm"
    ]

    private static let dismissCustomActionNames: Set<String> = [
        "close",
        "clear",
        "dismiss"
    ]

    /// Selects the Accessibility action that mimics clicking a native macOS
    /// notification banner so the source app receives the notification response
    /// (deep-linking to the exact chat, thread, or email).
    static func activateAction(from actions: [String]) -> String? {
        for preferred in preferredActivateActions where actions.contains(preferred) {
            return preferred
        }
        return nil
    }

    /// Selects the Accessibility action that dismisses a native macOS
    /// notification banner when the user explicitly clicks the notch close button.
    static func dismissAction(from actions: [String]) -> String? {
        if actions.contains("AXCancel") {
            return "AXCancel"
        }
        return actions.first { action in
            guard let customName = customActionName(from: action) else { return false }
            return dismissCustomActionNames.contains(customName.lowercased())
        }
    }

    static func customActionName(from action: String) -> String? {
        guard action.hasPrefix("Name:") else { return nil }
        let afterPrefix = action.dropFirst("Name:".count)
        let firstLine = afterPrefix.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
        let trimmed = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func isCloseOrOptionsControl(subrole: String?, identifier: String?) -> Bool {
        if subrole == "AXCloseButton" { return true }
        let loweredID = identifier?.lowercased() ?? ""
        return loweredID.contains("close")
            || loweredID.contains("clear")
            || loweredID.contains("dismiss")
            || loweredID.contains("option")
            || loweredID.contains("more")
    }
}
