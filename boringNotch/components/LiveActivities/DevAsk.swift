//
//  DevAsk.swift
//  zzz.notch
//
//  Questions from dev tooling that wait for an answer in the notch.
//
//  `zzz ask` connects to a Unix domain socket and sends one line:
//      zzznotch://ask?id=KEY&question=…&option=A&option=B[&multiple=1][&timeout=S]
//  The app keeps the connection open and shows the question in the Dev row
//  `dev-KEY`. It writes one reply line when the question is answered: the
//  chosen options joined by U+001F, or an empty line on timeout, when a newer
//  ask replaces it, or when the client disconnects. Then it closes the socket.
//

import AppKit
import Darwin
import SwiftUI

struct DevAsk: Identifiable, Sendable {
    /// Event id, same "dev-" prefixed form as `DevEventURL` ids.
    let id: String
    let question: String
    let options: [String]
    let multiple: Bool
}

struct DevAskRequest: Sendable {
    let ask: DevAsk
    let timeout: TimeInterval
}

enum DevAskURL {
    static let maxOptions = 6
    static let defaultTimeout: TimeInterval = 120

    /// Parses one request line. Returns nil when the line is not a valid ask.
    static func request(from line: String) -> DevAskRequest? {
        guard let url = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == DevEventURL.scheme,
              url.host?.lowercased() == "ask",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        var single: [String: String] = [:]
        var options: [String] = []
        for item in items {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            if item.name == "option" {
                options.append(value)
            } else {
                single[item.name] = value
            }
        }

        guard let key = single["id"], let question = single["question"],
              (1...maxOptions).contains(options.count)
        else { return nil }

        var timeout = single["timeout"].flatMap(TimeInterval.init) ?? defaultTimeout
        if !timeout.isFinite { timeout = defaultTimeout }
        let multiple = single["multiple"] == "1" || single["multiple"] == "true"

        return DevAskRequest(
            ask: DevAsk(id: "dev-" + key, question: question, options: options, multiple: multiple),
            timeout: min(max(timeout, 5), 600)
        )
    }
}

/// Listening socket and client connections. Every piece of mutable state is
/// confined to `queue`; `start` and `finish` are the only entry points called
/// from other threads.
final class DevAskSocket: @unchecked Sendable {
    enum Event: Sendable {
        case received(client: Int, request: DevAskRequest)
        case ended(client: Int)
    }

    static var path: String { "/tmp/zzznotch-\(getuid()).sock" }

    private struct Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var requested = false
        var buffer: [UInt8] = []
        var timer: DispatchSourceTimer?
        /// The client half-closed after sending its request (macOS `nc`
        /// does on stdin EOF); reading is suspended until the reply.
        var suspended = false
    }

    private let queue = DispatchQueue(label: "zzznotch.ask.socket")
    private var listener: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextID = 0
    private var onEvent: (@Sendable (Event) -> Void)?

    /// Binds the socket and starts accepting. Events are delivered on the
    /// socket's private queue.
    func start(_ handler: @escaping @Sendable (Event) -> Void) -> Bool {
        queue.sync { () -> Bool in
            guard listener < 0 else { return true }
            guard let fd = makeListener(path: DevAskSocket.path) else { return false }
            listener = fd
            onEvent = handler

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients() }
            source.resume()
            listenSource = source
            return true
        }
    }

    /// Writes the reply line to client `client` and closes it. No-op when that
    /// client already left.
    func finish(client: Int, selections: [String]) {
        queue.async { self.reply(client, selections) }
    }

    private func makeListener(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() {
                raw[index] = UInt8(bitPattern: byte)
            }
        }

        unlink(path)
        // Owner-only socket file: the mask applies to the bind() call only.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)

        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func acceptClients() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            adopt(fd)
        }
    }

    private func adopt(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        nextID += 1
        let id = nextID
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readable(id) }
        source.setCancelHandler { close(fd) }
        connections[id] = Connection(fd: fd, source: source)
        source.resume()
    }

    private func readable(_ id: Int) {
        guard let fd = connections[id]?.fd else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while connections[id] != nil {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                teardown(id)
                return
            }
            guard n > 0 else {
                if connections[id]?.requested == true {
                    // Half-close after the request: still waiting for the
                    // answer. Stop reading; the reply or timeout ends it.
                    connections[id]?.suspended = true
                    connections[id]?.source.suspend()
                } else {
                    teardown(id)
                }
                return
            }
            if connections[id]?.requested == true { continue }

            connections[id]?.buffer.append(contentsOf: chunk[0..<n])
            guard let buffer = connections[id]?.buffer else { return }
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                connections[id]?.requested = true
                connections[id]?.buffer = []
                handle(line: line, id: id)
            } else if buffer.count > 8192 {
                reply(id, [])
                return
            }
        }
    }

    private func handle(line: String, id: Int) {
        guard let request = DevAskURL.request(from: line) else {
            reply(id, [])
            return
        }
        onEvent?(.received(client: id, request: request))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.reply(id, []) }
        timer.schedule(deadline: .now() + request.timeout)
        timer.resume()
        connections[id]?.timer = timer
    }

    private func reply(_ id: Int, _ selections: [String]) {
        guard let conn = connections[id] else { return }
        let line = Array((selections.joined(separator: "\u{1F}") + "\n").utf8)
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(conn.fd, base + sent, raw.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                sent += n
            }
        }
        teardown(id)
    }

    private func teardown(_ id: Int) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.timer?.cancel()
        if conn.suspended { conn.source.resume() }   // a suspended source never runs its cancel handler
        conn.source.cancel()  // the cancel handler closes the descriptor
        onEvent?(.ended(client: id))
    }
}

/// Pending questions shown in the Dev tab, plus the socket they arrive on.
@MainActor
final class DevAskCenter: ObservableObject {
    static let shared = DevAskCenter()

    /// Open questions by event id.
    @Published private(set) var pending: [String: DevAsk] = [:]

    private let socket = DevAskSocket()
    /// Socket client waiting on each pending question.
    private var clients: [String: Int] = [:]
    /// Pending question ids, oldest first.
    private var arrivals: [String] = []
    private var started = false
    private var keyMonitors: [Any] = []

    private init() {}

    /// Opens the socket and installs the ⌃⌥⌘1…6 monitors. Safe to call twice.
    func start() {
        guard !started else { return }
        started = true

        let bound = socket.start { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DevAskCenter.shared.receive(event) }
            }
        }
        if !bound {
            NSLog("zzz.notch: could not open ask socket at %@", DevAskSocket.path)
        }
        installKeyMonitors()
    }

    /// Sends `selections` to the client waiting on `id` and removes the question.
    func answer(_ id: String, with selections: [String]) {
        guard let client = clients[id] else { return }
        forget(id)
        socket.finish(client: client, selections: selections)
    }

    private func receive(_ event: DevAskSocket.Event) {
        switch event {
        case .received(let client, let request):
            let id = request.ask.id
            if let old = clients[id] {
                socket.finish(client: old, selections: [])
            }
            forget(id)
            pending[id] = request.ask
            clients[id] = client
            arrivals.append(id)

        case .ended(let client):
            if let id = clients.first(where: { $0.value == client })?.key {
                forget(id)
            }
        }
    }

    private func forget(_ id: String) {
        pending[id] = nil
        clients[id] = nil
        arrivals.removeAll { $0 == id }
    }

    /// ⌃⌥⌘1…6 answers the newest single-choice question with that option.
    private func answerWithShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.control, .option, .command],
              let key = event.charactersIgnoringModifiers, key.count == 1,
              let number = key.first?.wholeNumberValue,
              (1...DevAskURL.maxOptions).contains(number),
              let ask = arrivals.reversed().compactMap({ pending[$0] }).first(where: { !$0.multiple }),
              number <= ask.options.count
        else { return false }

        answer(ask.id, with: [ask.options[number - 1]])
        return true
    }

    private func installKeyMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { _ = DevAskCenter.shared.answerWithShortcut(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            let handled = MainActor.assumeIsolated { DevAskCenter.shared.answerWithShortcut(event) }
            return handled ? nil : event
        }
        keyMonitors = [global, local].compactMap { $0 }
    }
}

/// Compact question and option buttons for a Dev row.
struct DevAskView: View {
    let ask: DevAsk
    @State private var chosen: Set<String> = []

    private let columns = [
        GridItem(.flexible(), spacing: 6, alignment: .leading),
        GridItem(.flexible(), spacing: 6, alignment: .leading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(ask.options.indices, id: \.self) { index in
                    optionButton(index: index)
                }
            }

            if ask.multiple {
                Button("Send") {
                    DevAskCenter.shared.answer(ask.id, with: ask.options.filter { chosen.contains($0) })
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.yellow))
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.4 : 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func optionButton(index: Int) -> some View {
        let option = ask.options[index]
        let isOn = chosen.contains(option)
        return Button {
            guard ask.multiple else {
                DevAskCenter.shared.answer(ask.id, with: [option])
                return
            }
            if isOn {
                chosen.remove(option)
            } else {
                chosen.insert(option)
            }
        } label: {
            HStack(spacing: 4) {
                if !ask.multiple {
                    Text("⌃⌥⌘\(index + 1)")
                        .font(.system(size: 8, design: .monospaced))
                        .opacity(0.6)
                }
                Text(option)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(isOn ? Color.yellow : Color.yellow.opacity(0.18)))
            .foregroundStyle(isOn ? Color.black : Color.yellow)
        }
        .buttonStyle(.plain)
    }
}
