//
//  SystemNotificationManager.swift
//  boringNotch
//
import AppKit
import Combine
import Defaults

struct SystemNotification: Identifiable, Equatable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    var receivedAt: Date
    /// Set only for dev events (`zzznotch://notify`).
    var symbol: String? = nil
    var status: DevEventStatus? = nil
    var actionURL: URL? = nil
    var displayDuration: TimeInterval? = nil
    var activity: String? = nil
    var agents: Int? = nil
    var prompt: String? = nil
    /// Headline of the current step, e.g. "Running a command".
    var now: String? = nil
    /// Why the current step runs, e.g. "Run the auth tests".
    var intent: String? = nil
    /// Raw command, path or pattern of the current step; shown monospaced.
    var command: String? = nil
    /// Plan position, e.g. "Step 3 of 5 · Writing the auth tests".
    var step: String? = nil
    /// Running subagents, one per line as "name · task".
    var agentList: String? = nil
    /// Owning process id; when it exits, the ongoing dev session auto-clears.
    var pid: Int32? = nil
    /// Context window utilization (0...100), shown as a subtle bar in the Dev card.
    var contextPercent: Int? = nil
    /// Optional tmux pane target (e.g. "%3") focused before activating the terminal app.
    var tmuxPane: String? = nil
}

struct NotificationHistoryEntry: Identifiable, Equatable, Codable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    var receivedAt: Date
    var symbol: String?
    var status: DevEventStatus?
    var actionURL: URL?
    var tmuxPane: String?
    var isRead: Bool

    init(from notification: SystemNotification, isRead: Bool = false) {
        self.id = notification.id
        self.appName = notification.appName
        self.bundleID = notification.bundleID
        self.title = notification.title
        self.subtitle = notification.subtitle
        self.body = notification.body
        self.receivedAt = notification.receivedAt
        self.symbol = notification.symbol
        self.status = notification.status
        self.actionURL = notification.actionURL
        self.tmuxPane = notification.tmuxPane
        self.isRead = isRead
    }

    var asNotification: SystemNotification {
        SystemNotification(
            id: id,
            appName: appName,
            bundleID: bundleID,
            title: title,
            subtitle: subtitle,
            body: body,
            receivedAt: receivedAt,
            symbol: symbol,
            status: status,
            actionURL: actionURL,
            tmuxPane: tmuxPane
        )
    }
}

@MainActor
final class SystemNotificationManager: ObservableObject {
    static let shared = SystemNotificationManager()

    static let historyLimit = 50
    static let historyRetention: TimeInterval = 24 * 60 * 60

    @Published private(set) var activeNotification: SystemNotification?
    @Published private(set) var queuedNotifications: [SystemNotification] = []
    @Published private(set) var history: [NotificationHistoryEntry] = []

    var unreadCount: Int {
        history.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }

    private let queueLimit = 5
    private let displayDuration: TimeInterval = 8
    private let historyStorageURL: URL?
    private var dismissTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private var xpcInterruptObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var isUserPresent = false

    private lazy var watchSupervisor = NotificationWatchSupervisor(
        isAuthorized: {
            await XPCHelperClient.shared.isAccessibilityAuthorized()
        },
        syncFilter: {
            await XPCHelperClient.shared.syncNotificationFilter(
                bundleIDs: Defaults[.notificationAllowedApps],
                allApps: Defaults[.notificationsFromAllApps]
            )
        },
        startWatching: {
            await XPCHelperClient.shared.startNotificationWatching()
        },
        stopWatching: {
            XPCHelperClient.shared.stopNotificationWatching()
        }
    )

    static var defaultHistoryStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("notification-history.json")
    }

    init(storageURL: URL? = SystemNotificationManager.defaultHistoryStorageURL, observeSystemNotifications: Bool = true) {
        self.historyStorageURL = storageURL
        loadHistory()
        if observeSystemNotifications {
            notificationObserver = NotificationCenter.default.addObserver(
                forName: .systemNotificationDidAppear, object: nil, queue: .main
            ) { [weak self] note in
                guard let payload = note.userInfo as? [String: String] else { return }
                Task { @MainActor in self?.add(payload) }
            }
            xpcInterruptObserver = NotificationCenter.default.addObserver(
                forName: .xpcHelperConnectionDidInterrupt, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.watchSupervisor.handleHelperDisconnected() }
            }
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            workspaceWakeObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.watchSupervisor.handleSystemWake() }
            }
            screensWakeObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.watchSupervisor.handleSystemWake() }
            }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        if let xpcInterruptObserver {
            NotificationCenter.default.removeObserver(xpcInterruptObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let workspaceWakeObserver {
            workspaceCenter.removeObserver(workspaceWakeObserver)
        }
        if let screensWakeObserver {
            workspaceCenter.removeObserver(screensWakeObserver)
        }
    }

    func start() async {
        await watchSupervisor.start()
    }

    func stop() {
        watchSupervisor.stop()
        queuedNotifications.removeAll()
        isUserPresent = false
        dismissActive()
    }

    func holdActive() {
        isUserPresent = true
        dismissTask?.cancel()
        dismissTask = nil
    }

    func resumeDismiss(after delay: TimeInterval = 2) {
        isUserPresent = false
        queuedNotifications.removeAll()
        guard let notification = activeNotification else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: notification.id)
        }
    }

    func dismissActive(
        token: String? = nil,
        dismissNative: Bool = false,
        removeFromHistory: Bool = false
    ) {
        guard token == nil || activeNotification?.id == token else { return }
        let dismissed = activeNotification
        dismissTask?.cancel()
        dismissTask = nil
        activeNotification = nil
        if let dismissed {
            if dismissNative && dismissed.status == nil {
                XPCHelperClient.shared.dismissNotification(token: dismissed.id)
            }
            if removeFromHistory {
                self.removeFromHistory(id: dismissed.id)
            }
        }
        if isUserPresent {
            promoteNext()
        } else {
            queuedNotifications.removeAll()
        }
    }

    func showNextQueued() {
        guard isUserPresent, let next = queuedNotifications.first else { return }
        if let activeNotification {
            queuedNotifications.append(activeNotification)
        }
        queuedNotifications.removeFirst()
        show(next)
    }

    func open(_ notification: SystemNotification) async -> Bool {
        if let pane = notification.tmuxPane, !pane.isEmpty {
            await Self.focusTmuxPane(pane)
        }

        let workspace = NSWorkspace.shared
        if let actionURL = notification.actionURL {
            return workspace.open(actionURL)
        }

        // For mirrored macOS notifications, trigger the native banner's AX
        // click action first so NotificationCenter delivers the app's full
        // UNNotificationResponse (deep-linking into the exact chat/email/thread).
        if notification.status == nil,
           await XPCHelperClient.shared.activateNotification(token: notification.id) {
            return true
        }

        for bundleID in candidateBundleIDs(for: notification) {
            let running = workspace.runningApplications.first { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }

            // Prefer NSWorkspace.openApplication over NSRunningApplication.activate:
            // on macOS 14+ it bypasses cooperative-activation restrictions from
            // accessory panels and triggers applicationShouldHandleReopen when
            // windows were closed or minimized.
            if let appURL = running?.bundleURL ?? workspace.urlForApplication(withBundleIdentifier: bundleID),
               await launchApplication(at: appURL) {
                return true
            }

            if let running, running.activate(options: [.activateAllWindows]) {
                return true
            }
        }

        return false
    }

    private func add(_ payload: [String: String]) {
        guard let token = payload["token"], !token.isEmpty else { return }
        let appName = nonEmpty(payload["appName"])
        var bundleID = nonEmpty(payload["bundleID"]).map {
            normalizeBundleIdentifier($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The helper only has the banner's display name and can miss when the
        // source is a helper process or is no longer running. Re-resolve here
        // so both the icon and launch action get the real application.
        if bundleID.map(isLaunchable) != true,
           let appName,
           let resolved = BundleIDResolver.shared.bundleID(forAppNamed: appName) {
            let resolved = normalizeBundleIdentifier(resolved)
            bundleID = resolved
        }

        let notification = SystemNotification(
            id: token,
            appName: appName,
            bundleID: bundleID,
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"]),
            receivedAt: Date()
        )
        guard isAllowed(notification) else { return }
        recordInHistory(notification)
        enqueue(notification)
    }

    /// Shows an event pushed by local dev tooling. Skips the mirrored-app
    /// filter; an event reusing a live id replaces that one in place, so a
    /// tool can update a status ("running" → "done") without stacking.
    func post(_ notification: SystemNotification) {
        if notification.status != .run && notification.status != .idle {
            recordInHistory(notification)
        }
        if activeNotification?.id == notification.id {
            if isUserPresent {
                activeNotification = notification
            } else {
                show(notification)
            }
            return
        }
        if let index = queuedNotifications.firstIndex(where: { $0.id == notification.id }) {
            queuedNotifications[index] = notification
            return
        }
        enqueue(notification)
    }

    // MARK: - Notification History

    func recordInHistory(_ notification: SystemNotification, now: Date = Date()) {
        pruneExpiredHistory(now: now, persist: false)
        history.removeAll { $0.id == notification.id }
        history.insert(NotificationHistoryEntry(from: notification, isRead: false), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        saveHistory()
    }

    func markAllHistoryRead() {
        var changed = false
        for index in history.indices where !history[index].isRead {
            history[index].isRead = true
            changed = true
        }
        if changed {
            saveHistory()
        }
    }

    func markHistoryRead(id: String) {
        guard let index = history.firstIndex(where: { $0.id == id }), !history[index].isRead else {
            return
        }
        history[index].isRead = true
        saveHistory()
    }

    func removeFromHistory(id: String) {
        let before = history.count
        history.removeAll { $0.id == id }
        if history.count != before {
            saveHistory()
        }
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        saveHistory()
    }

    func pruneExpiredHistory(now: Date = Date()) {
        pruneExpiredHistory(now: now, persist: true)
    }

    func openHistoryEntry(_ entry: NotificationHistoryEntry) async -> Bool {
        let opened = await open(entry.asNotification)
        removeFromHistory(id: entry.id)
        return opened
    }

    private func pruneExpiredHistory(now: Date, persist: Bool) {
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        let before = history.count
        history.removeAll { $0.receivedAt < cutoff }
        if persist && history.count != before {
            saveHistory()
        }
    }

    private func loadHistory(now: Date = Date()) {
        guard let url = historyStorageURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([NotificationHistoryEntry].self, from: data) else {
            return
        }
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        let fresh = decoded
            .filter { $0.receivedAt >= cutoff }
            .prefix(Self.historyLimit)
        history = Array(fresh)
        if history.count != decoded.count {
            saveHistory()
        }
    }

    private func saveHistory() {
        guard let url = historyStorageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func enqueue(_ notification: SystemNotification) {
        guard activeNotification == nil else {
            guard isUserPresent else {
                show(notification)
                return
            }
            guard !queuedNotifications.contains(where: { $0.id == notification.id }) else { return }
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                queuedNotifications.removeFirst()
            }
            return
        }
        show(notification)
    }

    private func show(_ notification: SystemNotification) {
        dismissTask?.cancel()
        activeNotification = notification
        scheduleDismiss(for: notification.id, after: notification.displayDuration ?? displayDuration)
    }

    private func scheduleDismiss(for token: String, after delay: TimeInterval) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: token)
        }
    }

    private func promoteNext() {
        guard activeNotification == nil, !queuedNotifications.isEmpty else { return }
        show(queuedNotifications.removeFirst())
    }

    func updateFilter() {
        XPCHelperClient.shared.setNotificationFilter(
            bundleIDs: Defaults[.notificationAllowedApps],
            allApps: Defaults[.notificationsFromAllApps]
        )
    }

    private func isAllowed(_ notification: SystemNotification) -> Bool {
        if Defaults[.notificationsFromAllApps] { return true }
        if let bundleID = notification.bundleID {
            return Defaults[.notificationAllowedApps].contains(bundleID)
        }
        guard let appName = notification.appName.map(BundleIDResolver.normalizedAppName),
              !appName.isEmpty else {
            return false
        }
        return Defaults[.notificationAllowedApps].contains { bundleID in
            guard let lastComponent = bundleID.split(separator: ".").last else { return false }
            return appName == BundleIDResolver.normalizedAppName(String(lastComponent))
        }
    }

    private func candidateBundleIDs(for notification: SystemNotification) -> [String] {
        let resolved: String?
        if let bundleID = notification.bundleID, isLaunchable(bundleID) {
            resolved = nil
        } else {
            resolved = notification.appName.flatMap {
                BundleIDResolver.shared.bundleID(forAppNamed: $0)
            }
        }
        return Self.bundleIDCandidates(for: notification, resolvedBundleID: resolved)
    }

    nonisolated static func bundleIDCandidates(
        for notification: SystemNotification,
        resolvedBundleID: String? = nil
    ) -> [String] {
        var result: [String] = []
        for candidate in [notification.bundleID, resolvedBundleID].compactMap({ $0 }) {
            let normalized = normalizeBundleIdentifier(candidate)
            guard !normalized.isEmpty, !result.contains(normalized) else { continue }
            result.append(normalized)
        }
        return result
    }

    private func isLaunchable(_ bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
            || workspace.runningApplications.contains { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }
    }

    private func launchApplication(at appURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func focusTmuxPane(_ pane: String) async {
        await Task.detached {
            guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else { return }
            for args in [["select-window", "-t", pane], ["select-pane", "-t", pane]] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tmux)
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
        }.value
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
