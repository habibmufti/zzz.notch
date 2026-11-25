//
//  NotificationWatcher.swift
//  BoringNotchXPCHelper
//
import AppKit
import ApplicationServices
import Foundation

private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let orderedChildrenAttribute = "AXOrderedChildren"
private let stackingIdentifierAttribute = "AXStackingIdentifier"
private let maxAccessibilityNodes = 1_024
private let maxTextNodes = 256
private let structuralIdentifiers: Set<String> = [
    "AXNotificationListItems",
    "widgets-overlay-view"
]
private let settleDelay: TimeInterval = 0.15

private extension AXUIElement {
    subscript(attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        self[attribute] as? String
    }

    func children() -> [AXUIElement] {
        (self[kAXChildrenAttribute] as? [AXUIElement] ?? [])
            + (self[orderedChildrenAttribute] as? [AXUIElement] ?? [])
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = self[attribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success,
              let list = names as? [String]
        else { return [] }
        return list
    }

    @discardableResult
    func performAction(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}

struct CapturedNotification {
    let token: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
}

final class NotificationWatcher {
    private final class ObserverContext: @unchecked Sendable {
        weak var watcher: NotificationWatcher?
    }

    var onBanner: ((CapturedNotification) -> Void)?

    private let transactionGuard: XPCTransactionGuard
    private var appElement: AXUIElement?
    private var observedPID: pid_t?
    private var axObserver: AXObserver?
    private var observerRunLoop: AXObserverRunLoop?
    private var observerContext: ObserverContext?
    private var processExitSource: DispatchSourceProcess?
    private var reattachWorkItem: DispatchWorkItem?
    private var shouldKeepWatching = false
    private var scanScheduled = false
    private var settleWorkItem: DispatchWorkItem?
    private var observedWindows: [CFHashCode: AXUIElement] = [:]
    private var liveTokens = Set<String>()
    private var liveBanners: [String: AXUIElement] = [:]
    private var allowedBundleIDs = Set<String>()
    private var mirrorAllApps = false
    private var parkedWindowByToken: [String: Int] = [:]
    private var parkedWindows: [Int: (window: AXUIElement, origin: CGPoint)] = [:]
    private var bundleIDCache: [String: String] = [:]

    private static let reattachDelays: [TimeInterval] = [0.5, 1.0, 2.0, 5.0, 10.0]
    private static let maxBundleIDCacheEntries = 128

    init(transactionGuard: XPCTransactionGuard = XPCTransactionGuard()) {
        self.transactionGuard = transactionGuard
    }

    var isRunning: Bool { appElement != nil }

    func configureFilter(bundleIDs: Set<String>, allApps: Bool) {
        allowedBundleIDs = bundleIDs
        mirrorAllApps = allApps
    }

    @discardableResult
    func start() -> Bool {
        reattachWorkItem?.cancel()
        reattachWorkItem = nil

        guard AXIsProcessTrusted() else {
            stop()
            return false
        }

        let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first

        if isRunning {
            if let application,
               observedPID == application.processIdentifier,
               observerRunLoop?.isRunning == true {
                shouldKeepWatching = true
                transactionGuard.acquire()
                scan()
                return true
            }
            teardownObserver()
        }

        guard let application else {
            return false
        }

        let pid = application.processIdentifier
        appElement = AXUIElementCreateApplication(pid)
        guard installObserver(for: pid) else {
            appElement = nil
            return false
        }

        observedPID = pid
        shouldKeepWatching = true
        transactionGuard.acquire()
        installProcessExitMonitor(for: pid)
        scan()
        return true
    }

    func stop() {
        shouldKeepWatching = false
        reattachWorkItem?.cancel()
        reattachWorkItem = nil
        teardownObserver()
        bundleIDCache.removeAll()
        transactionGuard.release()
    }

    private func teardownObserver() {
        processExitSource?.cancel()
        processExitSource = nil
        settleWorkItem?.cancel()
        settleWorkItem = nil
        observerContext?.watcher = nil
        if let observer = axObserver {
            if let appElement {
                removeObserverNotifications(from: appElement, observer: observer)
            }
            for window in observedWindows.values {
                removeObserverNotifications(from: window, observer: observer)
            }
        }
        observedWindows.removeAll()
        observerRunLoop?.stop()
        axObserver = nil
        observerRunLoop = nil
        observerContext = nil
        observedPID = nil
        scanScheduled = false
        liveTokens.removeAll()
        liveBanners.removeAll()
        restoreAllWindows()
        appElement = nil
    }

    private func installProcessExitMonitor(for pid: pid_t) {
        processExitSource?.cancel()
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, self.observedPID == pid else { return }
            NSLog("[boringNotch] NotificationCenter (pid \(pid)) exited; scheduling reattach")
            self.teardownObserver()
            if self.shouldKeepWatching {
                self.scheduleReattach(attempt: 0)
            }
        }
        source.resume()
        processExitSource = source
    }

    private func scheduleReattach(attempt: Int) {
        reattachWorkItem?.cancel()
        guard shouldKeepWatching else { return }
        guard attempt < Self.reattachDelays.count else {
            NSLog("[boringNotch] NotificationCenter did not respawn after reattach retries")
            shouldKeepWatching = false
            transactionGuard.release()
            return
        }

        let delay = Self.reattachDelays[attempt]
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldKeepWatching else { return }
            self.reattachWorkItem = nil
            if !self.start() {
                self.scheduleReattach(attempt: attempt + 1)
            }
        }
        reattachWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Triggers the native macOS Notification Center click action on a live
    /// banner so the target app receives its full notification payload (e.g.
    /// opening the exact WhatsApp chat, Slack channel, or Mail message).
    func activateBanner(token: String) -> Bool {
        guard let banner = resolveLiveBanner(for: token) else { return false }
        guard performActivateAction(on: banner) else { return false }
        liveBanners.removeValue(forKey: token)
        scheduleSettleScan()
        return true
    }

    /// Dismisses a live macOS Notification Center banner when the user
    /// explicitly clicks the notch close button.
    func dismissBanner(token: String) {
        guard let banner = resolveLiveBanner(for: token) else { return }
        _ = performDismissAction(on: banner)
        liveBanners.removeValue(forKey: token)
        scheduleSettleScan()
    }

    private func addObserverNotifications(to element: AXUIElement) -> Bool {
        guard let observer = axObserver, let context = observerContext else { return false }
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var registered = false
        for notification in NotificationObservationPolicy.structuralNotifications {
            let result = AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                refcon
            )
            if result == .success {
                registered = true
            }
        }
        return registered
    }

    private func removeObserverNotifications(from element: AXUIElement, observer: AXObserver) {
        for notification in NotificationObservationPolicy.structuralNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }

    private func refreshObservedWindows(using windows: [AXUIElement]) {
        var current = Set<CFHashCode>()
        for window in windows {
            let subrole = window.string(kAXSubroleAttribute)
            let identifier = window.string(kAXIdentifierAttribute)
            guard NotificationObservationPolicy.shouldObserveElement(
                subrole: subrole,
                identifier: identifier
            ) else { continue }

            let key = CFHash(window)
            current.insert(key)
            guard observedWindows[key] == nil else { continue }
            _ = addObserverNotifications(to: window)
            observedWindows[key] = window
        }

        let stale = observedWindows.keys.filter { !current.contains($0) }
        for key in stale {
            if let window = observedWindows.removeValue(forKey: key) {
                if let observer = axObserver {
                    removeObserverNotifications(from: window, observer: observer)
                }
            }
        }
    }

    private func installObserver(for processIdentifier: pid_t) -> Bool {
        var observer: AXObserver?
        let result = AXObserverCreate(processIdentifier, { _, element, notification, refcon in
            autoreleasepool {
                guard let refcon else { return }
                let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
                let name = notification as String
                let subrole = name == "AXUIElementDestroyed"
                    ? nil
                    : element.string(kAXSubroleAttribute)
                let identifier = name == "AXUIElementDestroyed"
                    ? nil
                    : element.string(kAXIdentifierAttribute)
                guard NotificationObservationPolicy.shouldScan(
                    notification: name,
                    subrole: subrole,
                    identifier: identifier
                ) else { return }
                DispatchQueue.main.async { [weak context] in
                    context?.watcher?.handleObserverEvent()
                }
            }
        }, &observer)
        guard result == .success, let observer, let appElement else { return false }

        let context = ObserverContext()
        context.watcher = self
        observerContext = context
        axObserver = observer
        guard addObserverNotifications(to: appElement) else {
            axObserver = nil
            observerContext = nil
            return false
        }

        let runLoop = AXObserverRunLoop(observer: observer, retainedContext: context)
        guard runLoop.start() else {
            runLoop.stop()
            removeObserverNotifications(from: appElement, observer: observer)
            axObserver = nil
            observerContext = nil
            return false
        }
        observerRunLoop = runLoop
        return true
    }

    private func handleObserverEvent() {
        scheduleScan()
        scheduleSettleScan()
    }

    private func scheduleSettleScan() {
        guard settleWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWorkItem = nil
            self.scan()
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.scan()
        }
    }

    private func scan() {
        autoreleasepool {
            guard let appElement else { return }
            let windows = (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? []
            refreshObservedWindows(using: windows)
            var seen = Set<String>()

            for window in windows {
                guard case .banners(let banners) = inspect(window) else { continue }

                for banner in banners {
                    let token = token(for: banner)
                    seen.insert(token)
                    if liveTokens.contains(token) {
                        liveBanners[token] = banner
                        continue
                    }

                    let notification = capture(banner, token: token)
                    guard mirrorAllApps || isAllowed(notification) else { continue }
                    guard park(window, for: token) else {
                        NSLog("[boringNotch] could not hide notification banner \(token)")
                        continue
                    }

                    liveTokens.insert(token)
                    liveBanners[token] = banner
                    onBanner?(notification)
                }
            }

            let removed = liveTokens.subtracting(seen)
            liveTokens.formIntersection(seen)
            for token in removed {
                liveBanners.removeValue(forKey: token)
                restoreWindowIfUnused(token)
            }
        }
    }

    private func resolveLiveBanner(for targetToken: String) -> AXUIElement? {
        if let cached = liveBanners[targetToken],
           !cached.actionNames().isEmpty || cached.string(kAXSubroleAttribute) != nil {
            return cached
        }
        guard let appElement else { return nil }
        for window in (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? [] {
            guard case .banners(let banners) = inspect(window) else { continue }
            for banner in banners where token(for: banner) == targetToken {
                liveBanners[targetToken] = banner
                return banner
            }
        }
        return nil
    }

    private func performActivateAction(on banner: AXUIElement) -> Bool {
        if let action = NotificationActionSelection.activateAction(from: banner.actionNames()),
           banner.performAction(action) {
            return true
        }

        // Some macOS versions attach AXPress to a primary button/group child
        // rather than the outer banner container.
        var pending = banner.children()
        var visited: Set<CFHashCode> = [CFHash(banner)]
        let maxSearchNodes = 64

        while !pending.isEmpty && visited.count < maxSearchNodes {
            let element = pending.removeFirst()
            guard visited.insert(CFHash(element)).inserted else { continue }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)
            if NotificationActionSelection.isCloseOrOptionsControl(subrole: subrole, identifier: identifier) {
                continue
            }

            if let action = NotificationActionSelection.activateAction(from: element.actionNames()),
               element.performAction(action) {
                return true
            }
            pending.append(contentsOf: element.children())
        }

        return banner.performAction(kAXPressAction)
    }

    private func performDismissAction(on banner: AXUIElement) -> Bool {
        if let action = NotificationActionSelection.dismissAction(from: banner.actionNames()),
           banner.performAction(action) {
            return true
        }

        var pending = banner.children()
        var visited: Set<CFHashCode> = [CFHash(banner)]
        let maxSearchNodes = 64

        while !pending.isEmpty && visited.count < maxSearchNodes {
            let element = pending.removeFirst()
            guard visited.insert(CFHash(element)).inserted else { continue }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)?.lowercased() ?? ""
            let isDismissControl = subrole == "AXCloseButton"
                || identifier.contains("close")
                || identifier.contains("clear")
                || identifier.contains("dismiss")

            if isDismissControl, element.performAction(kAXPressAction) {
                return true
            }
            pending.append(contentsOf: element.children())
        }

        return false
    }

    private enum WindowContents {
        case ignored
        case banners([AXUIElement])
    }

    private func inspect(_ root: AXUIElement) -> WindowContents {
        var pending: [(element: AXUIElement, insideBanner: Bool, insideList: Bool)] = [
            (root, false, false)
        ]
        var visited = Set<CFHashCode>()
        var banners: [AXUIElement] = []

        while let node = pending.popLast() {
            let element = node.element
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxAccessibilityNodes else { return .ignored }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)
            let stackingIdentifier = node.insideList && subrole == "AXButton"
                ? element.string(stackingIdentifierAttribute)
                : nil
            if NotificationPanelDetection.isPanel(
                subrole: subrole,
                identifier: identifier,
                stackingIdentifier: stackingIdentifier,
                insideNotificationList: node.insideList && !node.insideBanner
            ) || NotificationPanelDetection.isDesktopWidget(identifier: identifier) {
                return .ignored
            }

            if !node.insideBanner, NotificationPanelDetection.isBanner(subrole: subrole) {
                banners.append(element)
            }

            let childInsideBanner = node.insideBanner || NotificationPanelDetection.isBanner(subrole: subrole)
            let childInsideList = node.insideList
                || identifier == NotificationPanelDetection.panelListIdentifier
            pending.append(contentsOf: element.children().reversed().map {
                ($0, childInsideBanner, childInsideList)
            })
        }

        return banners.isEmpty ? .ignored : .banners(banners)
    }

    private func token(for banner: AXUIElement) -> String {
        if let identifier = banner.string(kAXIdentifierAttribute),
           !identifier.isEmpty,
           !structuralIdentifiers.contains(identifier) {
            return identifier
        }
        if let stackingIdentifier = banner.string(stackingIdentifierAttribute),
           !stackingIdentifier.isEmpty {
            return stackingIdentifier
        }

        return "ax-\(CFHash(banner))"
    }

    private func park(_ window: AXUIElement, for token: String) -> Bool {
        let key = Int(bitPattern: CFHash(window))
        if parkedWindows[key] == nil {
            guard let origin = window.point(kAXPositionAttribute) else { return false }
            parkedWindows[key] = (window, origin)
            var hidden = CGPoint(x: -10000, y: -10000)
            guard let value = AXValueCreate(.cgPoint, &hidden),
                  AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
            else {
                parkedWindows.removeValue(forKey: key)
                return false
            }
        }
        parkedWindowByToken[token] = key
        return true
    }

    private func restoreWindowIfUnused(_ token: String) {
        guard let key = parkedWindowByToken.removeValue(forKey: token),
              !parkedWindowByToken.values.contains(key),
              let parked = parkedWindows.removeValue(forKey: key)
        else { return }
        var origin = parked.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(parked.window, kAXPositionAttribute as CFString, value)
        }
    }

    private func restoreAllWindows() {
        for token in Array(parkedWindowByToken.keys) {
            restoreWindowIfUnused(token)
        }
        parkedWindowByToken.removeAll()
        parkedWindows.removeAll()
    }

    private func capture(_ banner: AXUIElement, token: String) -> CapturedNotification {
        let parts = collectText(in: banner)
        let description = (banner["AXAttributedDescription"] as? NSAttributedString)?.string
            ?? banner["AXAttributedDescription"] as? String
        let appName = description.flatMap { value in
            value.split(separator: ",", maxSplits: 1)
                .first
                .map { Self.cleanedAppName(String($0)) }
        }

        return CapturedNotification(
            token: token,
            appName: appName,
            bundleID: appName.flatMap(bundleID(forAppNamed:)),
            title: parts["title"],
            subtitle: parts["subtitle"],
            body: parts["body"]
        )
    }

    private func collectText(in root: AXUIElement) -> [String: String] {
        var parts: [String: String] = [:]
        var pending = [root]
        var visited = Set<CFHashCode>()

        while let element = pending.popLast() {
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxTextNodes else { break }

            if let identifier = element.string(kAXIdentifierAttribute),
               let value = element[kAXValueAttribute] as? String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch identifier {
                case "title":
                    parts["title"] = value
                case "header" where parts["title"] == nil:
                    parts["title"] = value
                case "subtitle":
                    parts["subtitle"] = value
                case "body":
                    parts["body"] = value
                default:
                    break
                }
            }

            pending.append(contentsOf: element.children().reversed())
        }

        return parts
    }

    private func bundleID(forAppNamed name: String) -> String? {
        let target = Self.normalizedAppName(name)
        guard !target.isEmpty else { return nil }
        if let cached = bundleIDCache[target] { return cached }

        let running = NSWorkspace.shared.runningApplications
            .filter {
                guard let localizedName = $0.localizedName else { return false }
                return Self.normalizedAppName(localizedName) == target
            }
            .sorted(by: Self.preferRegularApplication)
            .compactMap { $0.bundleIdentifier }
            .first

        if let resolved = resolveBundleID(
            forRunningBundleID: running,
            appName: name,
            target: target
        ) {
            if bundleIDCache.count >= Self.maxBundleIDCacheEntries {
                bundleIDCache.removeAll(keepingCapacity: true)
            }
            bundleIDCache[target] = resolved
            return resolved
        }
        return nil
    }

    private func resolveBundleID(
        forRunningBundleID runningBundleID: String?,
        appName: String,
        target: String
    ) -> String? {
        if let runningBundleID {
            return normalizedBundleIdentifier(runningBundleID)
        }

        let displayName = Self.cleanedAppName(appName)
        let withoutSpaces = displayName.replacingOccurrences(of: " ", with: "")
        let filenameCandidates = withoutSpaces == displayName
            ? [displayName]
            : [displayName, withoutSpaces]
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications")
        ]

        for directory in directories {
            for candidate in filenameCandidates where !candidate.isEmpty {
                let appURL = directory.appendingPathComponent(candidate).appendingPathExtension("app")
                if let bundleID = bundleIdentifier(at: appURL) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }

        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
                let names = [
                    entry.deletingPathExtension().lastPathComponent,
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ]
                if names.contains(where: { name in
                    guard let name else { return false }
                    return Self.normalizedAppName(name) == target
                }) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }
        return nil
    }

    private func bundleIdentifier(at appURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private func normalizedBundleIdentifier(_ bundleID: String) -> String {
        let lower = bundleID.lowercased()
        if lower.hasPrefix("com.apple.safaritechnologypreview.") {
            return "com.apple.SafariTechnologyPreview"
        }
        if lower.hasPrefix("com.apple.webkit.") || lower.hasPrefix("com.apple.safari.") {
            return "com.apple.Safari"
        }
        let components = bundleID.components(separatedBy: ".")
        if let helperIndex = components.firstIndex(where: { $0.lowercased() == "helper" }) {
            return components[0..<helperIndex].joined(separator: ".")
        }
        return bundleID
    }

    private static func normalizedAppName(_ name: String) -> String {
        cleanedAppName(name).lowercased()
    }

    private static func cleanedAppName(_ name: String) -> String {
        name.filter { !$0.unicodeScalars.allSatisfy(bidiControlCharacters.contains) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bidiControlCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{200E}\u{200F}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        return set
    }()

    private static func preferRegularApplication(
        _ lhs: NSRunningApplication,
        _ rhs: NSRunningApplication
    ) -> Bool {
        if lhs.activationPolicy == .regular, rhs.activationPolicy != .regular {
            return true
        }
        if rhs.activationPolicy == .regular, lhs.activationPolicy != .regular {
            return false
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private func isAllowed(_ notification: CapturedNotification) -> Bool {
        if let bundleID = notification.bundleID {
            return allowedBundleIDs.contains(bundleID)
        }
        guard let appName = notification.appName?.lowercased(), !appName.isEmpty else {
            return false
        }
        return allowedBundleIDs.contains { bundleID in
            guard let lastComponent = bundleID.split(separator: ".").last else { return false }
            return Self.normalizedAppName(appName) == Self.normalizedAppName(String(lastComponent))
        }
    }
}

private final class AXObserverRunLoop {
    private let observer: AXObserver
    /// Kept alive until the run loop exits and removes the AXObserver source so
    /// the unretained `refcon` pointer passed to AXObserverCreate can never
    /// dangle while an AX callback is in flight.
    private let retainedContext: AnyObject
    private let ready = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _runLoop: CFRunLoop?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    init(observer: AXObserver, retainedContext: AnyObject) {
        self.observer = observer
        self.retainedContext = retainedContext
    }

    func start() -> Bool {
        let thread = Thread { [self] in
            autoreleasepool {
                let runLoop = CFRunLoopGetCurrent()
                self.stateLock.lock()
                self._runLoop = runLoop
                self._isRunning = true
                self.stateLock.unlock()

                let source = AXObserverGetRunLoopSource(self.observer)
                CFRunLoopAddSource(runLoop, source, .defaultMode)
                self.ready.signal()
                CFRunLoopRun()
                CFRunLoopRemoveSource(runLoop, source, .defaultMode)

                self.stateLock.lock()
                self._isRunning = false
                self._runLoop = nil
                self.stateLock.unlock()
            }
        }
        thread.name = "com.habibmufti.zzznotch.ax-observer"
        thread.qualityOfService = .utility
        thread.start()
        return ready.wait(timeout: .now() + 1) == .success
    }

    func stop() {
        stateLock.lock()
        let runLoop = _runLoop
        _isRunning = false
        _runLoop = nil
        stateLock.unlock()

        guard let runLoop else { return }
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
    }
}
