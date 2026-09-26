import Foundation
import Darwin

/// Agent-only side channel used to stream SwiftTrace output from the DEBUG app.
///
/// This is intentionally separate from the InjectionNext wire protocol so the
/// upstream runtime can stay unmodified. The project-side AgentTraceBridge
/// connects to this server and forwards SwiftTrace.logOutput as JSON lines.
public final class AgentTraceServer {
    public let port: UInt16
    private let devicesEnabled: Bool
    private let logStore: AgentLogStore?

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
    private var pendingCallOrder: PendingCallOrderCommand?
    private var pendingInstances: PendingInstancesCommand?
    private var pendingXprobe: PendingXprobeCommand?
    private var pendingEval: PendingEvalCommand?
    private var lifetimeActive = false
    private var testResults: [InjectedTestResult] = []

    private let maximumBufferedEvents = 10_000
    private let maximumBufferedTestResults = 1_000

    // Lifetime tracing scans and interposes the app's main image. Mature apps
    // can legitimately take tens of seconds to initialize, so keep this
    // separate from the shorter interactive trace command timeouts.
    private let lifetimeStartTimeout: TimeInterval = 90

    public init(
        port: UInt16 = 8888,
        devicesEnabled: Bool = false,
        logStore: AgentLogStore? = nil
    ) {
        self.port = port
        self.devicesEnabled = devicesEnabled
        self.logStore = logStore
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
            s_addr: devicesEnabled
                ? UInt32(INADDR_ANY).bigEndian
                : inet_addr("127.0.0.1")
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
            let host = devicesEnabled ? "0.0.0.0" : "127.0.0.1"
            throw ControlError(
                code: "TRACE_BIND_FAILED",
                message: "Unable to bind \(host):\(port): \(String(cString: strerror(errno)))"
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

        logStore?.append(
            "Trace listener started on \(devicesEnabled ? "0.0.0.0" : "127.0.0.1"):\(port)."
        )

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

    public func injectedTestResults(
        limit: Int? = nil
    ) -> TestResultsResult {
        lock.lock()
        defer { lock.unlock() }

        var selected = testResults
        if let limit {
            let bounded = max(0, min(limit, maximumBufferedTestResults))
            if selected.count > bounded {
                selected = Array(selected.suffix(bounded))
            }
        }

        return TestResultsResult(
            connected: client != nil,
            results: selected
        )
    }

    public func clearInjectedTestResults()
        -> TestResultsResult {
        lock.lock()
        testResults.removeAll(
            keepingCapacity: true
        )
        let connected = client != nil
        lock.unlock()

        return TestResultsResult(
            connected: connected,
            results: []
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

    public func callOrderSnapshot()
        -> Result<CallOrderResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingCallOrderCommand()

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
        guard pendingCallOrder == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "CALL_ORDER_BUSY",
                    message: "Another call-order request is pending."
                )
            )
        }
        bridge = connected
        pendingCallOrder = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "call_order",
                filter: nil
            )
        } catch {
            clearCallOrderPending(pending)
            return .failure(
                ControlError(
                    code: "CALL_ORDER_FAILED",
                    message: String(describing: error)
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 10
        ) == .success else {
            clearCallOrderPending(pending)
            return .failure(
                ControlError(
                    code: "CALL_ORDER_TIMEOUT",
                    message: "Timed out waiting for runtime call order."
                )
            )
        }

        if let error = pending.error {
            clearCallOrderPending(pending)
            return .failure(
                ControlError(
                    code: "CALL_ORDER_FAILED",
                    message: error
                )
            )
        }

        let signatures = pending.signatures ?? []
        clearCallOrderPending(pending)

        return .success(
            CallOrderResult(
                signatures: signatures
            )
        )
    }

    public func instancesStart()
        -> Result<InstanceCountsResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingTraceCommand(
            expectedState: "instances_started"
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
                    message: "Another trace/lifetime command is pending."
                )
            )
        }
        bridge = connected
        pendingCommand = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "instances_start",
                filter: nil
            )
        } catch {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_TRACKING_FAILED",
                    message: String(describing: error)
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + lifetimeStartTimeout
        ) == .success else {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_TRACKING_TIMEOUT",
                    message: "Timed out waiting for lifetime tracking to start."
                )
            )
        }

        if let error = pending.error {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_TRACKING_FAILED",
                    message: error
                )
            )
        }

        clearPending(pending)
        lock.lock()
        lifetimeActive = true
        lock.unlock()

        return .success(
            InstanceCountsResult(
                active: true,
                counts: []
            )
        )
    }

    public func instancesRead()
        -> Result<InstanceCountsResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingInstancesCommand()

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
        guard pendingInstances == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "INSTANCE_READ_BUSY",
                    message: "Another instance-count request is pending."
                )
            )
        }
        bridge = connected
        pendingInstances = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "instances_read",
                filter: nil
            )
        } catch {
            clearInstancesPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_READ_FAILED",
                    message: String(describing: error)
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 10
        ) == .success else {
            clearInstancesPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_READ_TIMEOUT",
                    message: "Timed out waiting for instance counts."
                )
            )
        }

        if let error = pending.error {
            clearInstancesPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_READ_FAILED",
                    message: error
                )
            )
        }

        let counts = (pending.counts ?? [:])
            .map {
                InstanceCount(
                    type: $0.key,
                    count: $0.value
                )
            }
            .sorted {
                $0.count == $1.count
                    ? $0.type < $1.type
                    : $0.count > $1.count
            }

        lock.lock()
        let active = lifetimeActive
        lock.unlock()
        clearInstancesPending(pending)

        return .success(
            InstanceCountsResult(
                active: active,
                counts: counts
            )
        )
    }

    public func instancesStop()
        -> Result<InstanceCountsResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingTraceCommand(
            expectedState: "instances_stopped"
        )

        lock.lock()
        guard let connected = client else {
            lifetimeActive = false
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
                    message: "Another trace/lifetime command is pending."
                )
            )
        }
        bridge = connected
        pendingCommand = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "instances_stop",
                filter: nil
            )
        } catch {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_TRACKING_FAILED",
                    message: String(describing: error)
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 10
        ) == .success else {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_TRACKING_TIMEOUT",
                    message: "Timed out waiting for lifetime tracking to stop."
                )
            )
        }

        if let error = pending.error {
            clearPending(pending)
            return .failure(
                ControlError(
                    code: "INSTANCE_TRACKING_FAILED",
                    message: error
                )
            )
        }

        clearPending(pending)
        lock.lock()
        lifetimeActive = false
        lock.unlock()

        return .success(
            InstanceCountsResult(
                active: false,
                counts: []
            )
        )
    }

    public func xprobeSearch(
        pattern: String?
    ) -> Result<XprobeResult, ControlError> {
        requestXprobe(
            action: "xprobe_search",
            pattern: pattern,
            objectID: nil
        )
    }

    public func xprobeInspect(
        objectID: Int
    ) -> Result<XprobeResult, ControlError> {
        requestXprobe(
            action: "xprobe_inspect",
            pattern: nil,
            objectID: objectID
        )
    }

    public func eval(
        objectID: Int,
        code: String
    ) -> Result<EvalResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingEvalCommand()

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
        guard pendingEval == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "EVAL_BUSY",
                    message: "Another Eval request is pending."
                )
            )
        }
        bridge = connected
        pendingEval = pending
        lock.unlock()

        do {
            try bridge.send(
                action: "eval",
                filter: nil,
                objectID: objectID,
                code: code
            )
        } catch {
            clearEvalPending(pending)
            return .failure(
                ControlError(
                    code: "EVAL_FAILED",
                    message: "Unable to send Eval request: \(error)"
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 30
        ) == .success else {
            clearEvalPending(pending)
            return .failure(
                ControlError(
                    code: "EVAL_TIMEOUT",
                    message: "Timed out waiting for runtime Eval."
                )
            )
        }

        if let error = pending.error {
            clearEvalPending(pending)
            return .failure(
                ControlError(
                    code: pending.available == false
                        ? "XPROBE_UNAVAILABLE"
                        : "EVAL_FAILED",
                    message: error
                )
            )
        }

        let result = pending.result
            ?? EvalResult(
                available: true,
                objectID: objectID,
                succeeded: false,
                error: "Runtime returned no Eval result."
            )
        clearEvalPending(pending)
        return .success(result)
    }

    private func requestXprobe(
        action: String,
        pattern: String?,
        objectID: Int?
    ) -> Result<XprobeResult, ControlError> {
        let bridge: TraceBridgeClient
        let pending = PendingXprobeCommand()

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
        guard pendingXprobe == nil else {
            lock.unlock()
            return .failure(
                ControlError(
                    code: "XPROBE_BUSY",
                    message: "Another Xprobe request is pending."
                )
            )
        }
        bridge = connected
        pendingXprobe = pending
        lock.unlock()

        do {
            try bridge.send(
                action: action,
                filter: pattern,
                objectID: objectID
            )
        } catch {
            clearXprobePending(pending)
            return .failure(
                ControlError(
                    code: "XPROBE_FAILED",
                    message: "Unable to send Xprobe request: \(error)"
                )
            )
        }

        guard pending.semaphore.wait(
            timeout: .now() + 30
        ) == .success else {
            clearXprobePending(pending)
            return .failure(
                ControlError(
                    code: "XPROBE_TIMEOUT",
                    message: "Timed out waiting for Xprobe."
                )
            )
        }

        if let error = pending.error {
            let available = pending.available
            clearXprobePending(pending)
            return .failure(
                ControlError(
                    code: available == false
                        ? "XPROBE_UNAVAILABLE"
                        : "XPROBE_FAILED",
                    message: error
                )
            )
        }

        let result = pending.result
            ?? XprobeResult(
                available: true,
                error: "Runtime returned no Xprobe result."
            )
        clearXprobePending(pending)
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

            guard bridge.validateHello() else {
                logStore?.append(
                    "Rejected trace bridge connection: invalid or unsupported hello.",
                    level: "warning"
                )
                continue
            }

            lock.lock()
            guard client == nil else {
                lock.unlock()
                logStore?.append(
                    "Rejected trace bridge connection: another bridge is already active.",
                    level: "warning"
                )
                continue
            }
            client = bridge
            lock.unlock()

            logStore?.append(
                "Trace bridge connected."
            )

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
                    if let order = self.pendingCallOrder {
                        order.error = "AgentTraceBridge disconnected."
                        self.pendingCallOrder = nil
                        order.semaphore.signal()
                    }
                    if let instances = self.pendingInstances {
                        instances.error = "AgentTraceBridge disconnected."
                        self.pendingInstances = nil
                        instances.semaphore.signal()
                    }
                    if let xprobe = self.pendingXprobe {
                        xprobe.error = "AgentTraceBridge disconnected."
                        self.pendingXprobe = nil
                        xprobe.semaphore.signal()
                    }
                    if let eval = self.pendingEval {
                        eval.error = "AgentTraceBridge disconnected."
                        self.pendingEval = nil
                        eval.semaphore.signal()
                    }
                    self.lifetimeActive = false
                    self.logStore?.append(
                        "Trace bridge disconnected.",
                        level: "warning"
                    )
                }
                self.lock.unlock()
            }
        }
    }

    private func handle(
        _ message: TraceBridgeMessage
    ) {
        if message.type == "xprobe_result" {
            lock.lock()
            let pending = pendingXprobe
            if let pending {
                let available = message.available ?? false
                pending.available = available
                pending.result = XprobeResult(
                    available: available,
                    objects: message.objects ?? [],
                    selected: message.selected,
                    details: message.details,
                    error: message.error
                )
                pending.error = message.error
                pendingXprobe = nil
                pending.semaphore.signal()
            }
            lock.unlock()
            return
        }

        if message.type == "eval_result" {
            lock.lock()
            let pending = pendingEval
            if let pending {
                let available = message.available ?? false
                pending.available = available
                pending.result = EvalResult(
                    available: available,
                    objectID: message.objectID ?? -1,
                    succeeded: message.succeeded ?? false,
                    error: message.error
                )
                pending.error = message.error
                pendingEval = nil
                pending.semaphore.signal()
            }
            lock.unlock()
            return
        }

        if message.type == "test_result" {
            guard let name = message.testName,
                  let passed = message.passed,
                  let failures = message.failures else {
                return
            }

            lock.lock()
            testResults.append(
                InjectedTestResult(
                    name: name,
                    passed: passed,
                    failures: failures,
                    durationSeconds:
                        message.durationSeconds,
                    messages:
                        message.messages ?? []
                )
            )
            if testResults.count >
                maximumBufferedTestResults {
                testResults.removeFirst(
                    testResults.count -
                    maximumBufferedTestResults
                )
            }
            lock.unlock()
            return
        }

        if message.type == "call_order" {
            lock.lock()
            let pending = pendingCallOrder
            if let pending {
                pending.signatures =
                    message.signatures
                pendingCallOrder = nil
                pending.semaphore.signal()
            }
            lock.unlock()
            return
        }

        if message.type == "instance_counts" {
            lock.lock()
            let pending = pendingInstances
            if let pending {
                pending.counts = message.counts
                pendingInstances = nil
                pending.semaphore.signal()
            }
            lock.unlock()
            return
        }

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
            if message.state == "error",
               let order = pendingCallOrder {
                order.error = message.error
                    ?? "Trace bridge reported an unknown error."
                pendingCallOrder = nil
                order.semaphore.signal()
            }
            if message.state == "error",
               let instances = pendingInstances {
                instances.error = message.error
                    ?? "Trace bridge reported an unknown error."
                pendingInstances = nil
                instances.semaphore.signal()
            }
            if message.state == "error",
               let xprobe = pendingXprobe {
                xprobe.error = message.error
                    ?? "Trace bridge reported an unknown error."
                pendingXprobe = nil
                xprobe.semaphore.signal()
            }
            if message.state == "error",
               let eval = pendingEval {
                eval.error = message.error
                    ?? "Trace bridge reported an unknown error."
                pendingEval = nil
                eval.semaphore.signal()
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

    private func clearCallOrderPending(
        _ pending: PendingCallOrderCommand
    ) {
        lock.lock()
        if pendingCallOrder === pending {
            pendingCallOrder = nil
        }
        lock.unlock()
    }

    private func clearInstancesPending(
        _ pending: PendingInstancesCommand
    ) {
        lock.lock()
        if pendingInstances === pending {
            pendingInstances = nil
        }
        lock.unlock()
    }

    private func clearXprobePending(
        _ pending: PendingXprobeCommand
    ) {
        lock.lock()
        if pendingXprobe === pending {
            pendingXprobe = nil
        }
        lock.unlock()
    }

    private func clearEvalPending(
        _ pending: PendingEvalCommand
    ) {
        lock.lock()
        if pendingEval === pending {
            pendingEval = nil
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

private final class PendingXprobeCommand {
    let semaphore = DispatchSemaphore(value: 0)
    var available = false
    var result: XprobeResult?
    var error: String?
}

private final class PendingEvalCommand {
    let semaphore = DispatchSemaphore(value: 0)
    var available = false
    var result: EvalResult?
    var error: String?
}

private final class PendingCallOrderCommand {
    let semaphore = DispatchSemaphore(value: 0)
    var signatures: [String]?
    var error: String?
}

private final class PendingInstancesCommand {
    let semaphore = DispatchSemaphore(value: 0)
    var counts: [String: Int]?
    var error: String?
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
    let protocolVersion: Int?
    let timestamp: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case timestamp
        case text
        case indent
        case state
        case error
        case elapsed
        case invocations
        case signatures
        case counts
        case testName
        case passed
        case failures
        case durationSeconds
        case messages
        case available
        case objects
        case selected
        case details
        case objectID
        case succeeded
    }
    let text: String?
    let indent: Int?
    let state: String?
    let error: String?
    let elapsed: [String: Double]?
    let invocations: [String: Int]?
    let signatures: [String]?
    let counts: [String: Int]?
    let testName: String?
    let passed: Bool?
    let failures: Int?
    let durationSeconds: Double?
    let messages: [String]?
    let available: Bool?
    let objects: [XprobeObject]?
    let selected: XprobeObject?
    let details: String?
    let objectID: Int?
    let succeeded: Bool?
}

private struct TraceBridgeCommand: Encodable {
    let action: String
    let filter: String?
    let scope: String?
    let name: String?
    let objectID: Int?
    let code: String?
}

private final class TraceBridgeClient {
    private let fd: Int32
    private let writeLock = NSLock()
    private let onEvent: (TraceBridgeMessage) -> Void
    private var initialBuffer = Data()

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

    func validateHello() -> Bool {
        var timeout = timeval(
            tv_sec: 2,
            tv_usec: 0
        )
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        defer {
            var disabled = timeval(
                tv_sec: 0,
                tv_usec: 0
            )
            _ = withUnsafePointer(to: &disabled) {
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    $0,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
        }

        var buffer = Data()
        var bytes = [UInt8](
            repeating: 0,
            count: 1024
        )

        while buffer.count <= 64 * 1024 {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(
                    fd,
                    $0.baseAddress,
                    $0.count
                )
            }

            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            if count == 0 {
                return false
            }

            buffer.append(contentsOf: bytes[0..<count])

            guard let newline = buffer.firstIndex(of: 0x0A) else {
                continue
            }

            let line = Data(buffer[..<newline])
            let remainderStart = buffer.index(after: newline)
            if remainderStart < buffer.endIndex {
                initialBuffer = Data(buffer[remainderStart...])
            }

            guard let message = try? JSONDecoder().decode(
                TraceBridgeMessage.self,
                from: line
            ) else {
                return false
            }

            return message.type == "hello" &&
                message.protocolVersion == 1
        }

        return false
    }

    func run() {
        var buffer = initialBuffer
        initialBuffer.removeAll(
            keepingCapacity: false
        )
        var bytes = [UInt8](
            repeating: 0,
            count: 4096
        )

        while true {
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
        name: String? = nil,
        objectID: Int? = nil,
        code: String? = nil
    ) throws {
        let command = TraceBridgeCommand(
            action: action,
            filter: filter,
            scope: scope,
            name: name,
            objectID: objectID,
            code: code
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
