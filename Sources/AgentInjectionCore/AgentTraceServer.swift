import Foundation
import Darwin

/// Agent-only side channel used to stream SwiftTrace output from the DEBUG app.
///
/// This is intentionally separate from the InjectionNext wire protocol so the
/// upstream runtime can stay unmodified. The project-side AgentTraceBridge
/// connects to this server and forwards SwiftTrace.logOutput as JSON lines.
public final class AgentTraceServer {
    public let port: UInt16

    private let queue = DispatchQueue(
        label: "agentInjectionIII.trace-server",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()

    private var listenerFD: Int32 = -1
    private var client: TraceBridgeClient?
    private var events: [TraceEvent] = []
    private var nextSequence: Int64 = 1
    private var active = false
    private var activeFilter: String?
    private var pendingCommand: PendingTraceCommand?
    private var pendingProfile: PendingProfileCommand?

    private let maximumBufferedEvents = 10_000

    public init(port: UInt16 = 8888) {
        self.port = port
    }

    deinit {
        if listenerFD >= 0 {
            Darwin.close(listenerFD)
        }
    }

    public func start() throws {
        guard listenerFD < 0 else { return }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlError(
                code: "TRACE_SOCKET_CREATE_FAILED",
                message: "socket() failed: \(String(cString: strerror(errno)))"
            )
        }

        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        _ = withUnsafePointer(to: &yes) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(
            s_addr: inet_addr("127.0.0.1")
        )

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        guard bindResult == 0 else {
            Darwin.close(fd)
            throw ControlError(
                code: "TRACE_BIND_FAILED",
                message: "Unable to bind 127.0.0.1:\(port): \(String(cString: strerror(errno)))"
            )
        }

        guard Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw ControlError(
                code: "TRACE_LISTEN_FAILED",
                message: "listen() failed: \(String(cString: strerror(errno)))"
            )
        }

        listenerFD = fd

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func status() -> TraceResult {
        lock.lock()
        defer { lock.unlock() }

        return TraceResult(
            connected: client != nil,
            active: active,
            filter: activeFilter,
            events: []
        )
    }

    public func startTrace(
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        let client: TraceBridgeClient
        let pending = PendingTraceCommand(
            expectedState: "started"
        )

        lock.lock()
        guard let connected = self.client else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_BRIDGE_NOT_CONNECTED",
                    message: "AgentTraceBridge is not connected. Ensure the embedded agent runtime bootstrap is active."
                )
            )
        }
        guard pendingCommand == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_BUSY",
                    message: "Another trace command is still pending."
                )
            )
        }
        client = connected
        events.removeAll(keepingCapacity: true)
        pendingCommand = pending
        lock.unlock()

        do {
            try client.send(
                action: "trace_start",
                filter: filter
            )
        } catch {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_FAILED",
                    message: "Unable to send trace_start: \(error)"
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 10
        ) == .success else {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_TIMEOUT",
                    message: "Timed out waiting for the app to confirm trace start."
                )
            )
        }

        if let error = pending.error {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_START_FAILED",
                    message: error
                )
            )
        }

        clearPending(pending)

        lock.lock()
        active = true
        activeFilter = filter
        let result = TraceResult(
            connected: true,
            active: true,
            filter: filter,
            events: []
        )
        lock.unlock()

        return .success(result)
    }

    public func startTraceScope(
        scope: String,
        name: String?,
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingTraceCommand(
            expectedState: "started"
        )

        lock.lock()
        guard let connected = client else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_BRIDGE_NOT_CONNECTED",
                    message: "AgentTraceBridge is not connected."
                )
            )
        }
        guard pendingCommand == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_BUSY",
                    message: "Another trace command is still pending."
                )
            )
        }

        bridge = connected
        events.removeAll(keepingCapacity: true)
        pendingCommand = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "trace_scope",
                filter: filter,
                scope: scope,
                name: name
            )
        } catch {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_FAILED",
                    message: "Unable to send scoped trace command: \(error)"
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 20
        ) == .success else {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_TIMEOUT",
                    message: "Timed out waiting for scoped tracing to start."
                )
            )
        }

        if let error = pending.error {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_START_FAILED",
                    message: error
                )
            )
        }

        clearPending(pending)

        lock.lock()
        active = true
        activeFilter = filter
        let result = TraceResult(
            connected: true,
            active: true,
            filter: filter,
            events: []
        )
        lock.unlock()

        return .success(result)
    }

    public func stopTrace()
        -> Result<TraceResult, ControlError> {
        let client: TraceBridgeClient
        let pending = PendingTraceCommand(
            expectedState: "stopped"
        )

        lock.lock()
        guard let connected = self.client else {
            active = false
            activeFilter = nil
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_BRIDGE_NOT_CONNECTED",
                    message: "AgentTraceBridge is not connected."
                )
            )
        }
        guard pendingCommand == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_BUSY",
                    message: "Another trace command is still pending."
                )
            )
        }
        client = connected
        pendingCommand = pending
        lock.unlock()

        do {
            try client.send(
                action: "trace_stop",
                filter: nil
            )
        } catch {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_FAILED",
                    message: "Unable to send trace_stop: \(error)"
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 10
        ) == .success else {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_COMMAND_TIMEOUT",
                    message: "Timed out waiting for the app to confirm trace stop."
                )
            )
        }

        if let error = pending.error {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "TRACE_STOP_FAILED",
                    message: error
                )
            )
        }

        clearPending(pending)

        lock.lock()
        active = false
        activeFilter = nil
        let result = TraceResult(
            connected: true,
            active: false,
            events: []
        )
        lock.unlock()

        return .success(result)
    }

    public func profileSnapshot(
        limit: Int?
    ) -> Result<ProfileResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingProfileCommand()

        lock.lock()
        guard let connected = client else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "TRACE_BRIDGE_NOT_CONNECTED",
                    message: "AgentTraceBridge is not connected."
                )
            )
        }
        guard pendingProfile == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "PROFILE_COMMAND_BUSY",
                    message: "Another profile snapshot is still pending."
                )
            )
        }
        bridge = connected
        pendingProfile = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "profile_snapshot",
                filter: nil
            )
        } catch {
            clearProfilePending(pending)
            return .failure(
                ControlError(
                    code: "PROFILE_COMMAND_FAILED",
                    message: "Unable to request profiling stats: \(error)"
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 10
        ) == .success else {
            clearProfilePending(pending)
            return .failure(
                ControlError(
                    code: "PROFILE_COMMAND_TIMEOUT",
                    message: "Timed out waiting for SwiftTrace profiling stats."
                )
            )
        }

        if let error = pending.error {
            clearProfilePending(pending)
            return .failure(
                ControlError(
                    code: "PROFILE_SNAPSHOT_FAILED",
                    message: error
                )
            )
        }

        let elapsed = pending.elapsed ?? [:]
        let invocations = pending.invocations ?? [:]
        let methods = Set(
            elapsed.keys
        ).union(invocations.keys)

        var stats = methods.map { method in
            let total = elapsed[method] ?? 0
            let count = invocations[method] ?? 0

            return ProfileStat(
                method: method,
                elapsedSeconds: total,
                invocations: count,
                averageMilliseconds: count > 0
                    ? total * 1000 / Double(count)
                    : 0
            )
        }
        .sorted {
            if $0.elapsedSeconds ==
               $1.elapsedSeconds {
                return $0.invocations >
                    $1.invocations
            }
            return $0.elapsedSeconds >
                $1.elapsedSeconds
        }

        if let limit {
            stats = Array(
                stats.prefix(
                    max(0, min(limit, 2_000))
                )
            )
        }

        clearProfilePending(pending)

        return .success(
            ProfileResult(
                connected: true,
                stats: stats
            )
        )
    }

    /// Returns and removes the oldest buffered trace events.
    public func readTrace(
        limit: Int?
    ) -> TraceResult {
        lock.lock()
        defer { lock.unlock() }

        let count = min(
            max(limit ?? events.count, 0),
            events.count
        )

        let drained = Array(events.prefix(count))
        if count > 0 {
            events.removeFirst(count)
        }

        return TraceResult(
            connected: client != nil,
            active: active,
            filter: activeFilter,
            events: drained
        )
    }

    private func acceptLoop() {
        while listenerFD >= 0 {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                continue
            }

            var yes: Int32 = 1
            _ = withUnsafePointer(to: &yes) {
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }

            let bridge = TraceBridgeClient(
                fd: fd,
                onEvent: { [weak self] message in
                    self?.handle(message)
                }
            )

            lock.lock()
            client = bridge
            lock.unlock()

            queue.async { [weak self, weak bridge] in
                guard let self, let bridge else { return }
                bridge.run()

                self.lock.lock()
                if self.client === bridge {
                    self.client = nil
                    self.active = false
                    self.activeFilter = nil
                    if let pending = self.pendingCommand {
                        pending.error = "AgentTraceBridge disconnected."
                        self.pendingCommand = nil
                        pending.semaphore.signal()
                    }
                    if let profile = self.pendingProfile {
                        profile.error = "AgentTraceBridge disconnected."
                        self.pendingProfile = nil
                        profile.semaphore.signal()
                    }
                }
                self.lock.unlock()
            }
        }
    }

    private func handle(
        _ message: TraceBridgeMessage
    ) {
        if message.type == "profile" {
            lock.lock()
            let pending = pendingProfile
            if let pending {
                pending.elapsed = message.elapsed
                pending.invocations =
                    message.invocations
                pendingProfile = nil
                pending.semaphore.signal()
            }
            lock.unlock()
            return
        }

        if message.type == "state" {
            lock.lock()
            let pending = pendingCommand

            if let pending {
                if message.state == pending.expectedState {
                    pendingCommand = nil
                    pending.semaphore.signal()
                } else if message.state == "error" {
                    pending.error = message.error
                        ?? "Trace bridge reported an unknown error."
                    pendingCommand = nil
                    pending.semaphore.signal()
                }
            }

            if message.state == "error",
               let profile = pendingProfile {
                profile.error = message.error
                    ?? "Trace bridge reported an unknown error."
                pendingProfile = nil
                profile.semaphore.signal()
            }

            lock.unlock()
            return
        }

        append(message)
    }

    private func clearPending(
        _ pending: PendingTraceCommand
    ) {
        lock.lock()
        if pendingCommand === pending {
            pendingCommand = nil
        }
        lock.unlock()
    }

    private func clearProfilePending(
        _ pending: PendingProfileCommand
    ) {
        lock.lock()
        if pendingProfile === pending {
            pendingProfile = nil
        }
        lock.unlock()
    }

    private func append(
        _ message: TraceBridgeMessage
    ) {
        guard message.type == "event",
              let text = message.text,
              !text.isEmpty else {
            return
        }

        lock.lock()
        let event = TraceEvent(
            sequence: nextSequence,
            timestamp: message.timestamp
                ?? Date.timeIntervalSinceReferenceDate,
            text: text,
            indent: message.indent
        )
        nextSequence += 1
        events.append(event)

        if events.count > maximumBufferedEvents {
            events.removeFirst(
                events.count - maximumBufferedEvents
            )
        }
        lock.unlock()
    }
}

private final class PendingProfileCommand {
    let semaphore = DispatchSemaphore(value: 0)
    var elapsed: [String: Double]?
    var invocations: [String: Int]?
    var error: String?
}

private final class PendingTraceCommand {
    let expectedState: String
    let semaphore = DispatchSemaphore(value: 0)
    var error: String?

    init(expectedState: String) {
        self.expectedState = expectedState
    }
}

private struct TraceBridgeMessage: Decodable {
    let type: String
    let timestamp: Double?
    let text: String?
    let indent: Int?
    let state: String?
    let error: String?
    let elapsed: [String: Double]?
    let invocations: [String: Int]?
}

private struct TraceBridgeCommand: Encodable {
    let action: String
    let filter: String?
    let scope: String?
    let name: String?
}

private final class TraceBridgeClient {
    private let fd: Int32
    private let writeLock = NSLock()
    private let onEvent: (TraceBridgeMessage) -> Void

    init(
        fd: Int32,
        onEvent: @escaping (TraceBridgeMessage) -> Void
    ) {
        self.fd = fd
        self.onEvent = onEvent
    }

    deinit {
        Darwin.close(fd)
    }

    func run() {
        var buffer = Data()
        var bytes = [UInt8](
            repeating: 0,
            count: 4096
        )

        while true {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(
                    fd,
                    $0.baseAddress,
                    $0.count
                )
            }

            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 {
                return
            }

            buffer.append(contentsOf: bytes[0..<count])

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)

                guard !line.isEmpty,
                      let message = try? JSONDecoder().decode(
                        TraceBridgeMessage.self,
                        from: line
                      ) else {
                    continue
                }

                onEvent(message)
            }

            if buffer.count > 8 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }

    func send(
        action: String,
        filter: String?,
        scope: String? = nil,
        name: String? = nil
    ) throws {
        let command = TraceBridgeCommand(
            action: action,
            filter: filter,
            scope: scope,
            name: name
        )

        var data = try JSONEncoder().encode(command)
        data.append(0x0A)

        writeLock.lock()
        defer { writeLock.unlock() }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }

            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset
                )

                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlError(
                        code: "TRACE_WRITE_FAILED",
                        message: "write() failed: \(String(cString: strerror(errno)))"
                    )
                }

                offset += written
            }
        }
    }
}
