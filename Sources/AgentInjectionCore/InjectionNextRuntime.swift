import Foundation
import Darwin
#if DEBUG
import InjectionImpl
#endif

// Wire-compatible subset of the InjectionNext client/server protocol.
// Protocol values are aligned with johnno1962/InjectionNext (MIT licensed).

private enum InjectionNextCommand: Int32 {
    case log = 0
    case load = 1
    case inject = 2
    case xcodePath = 3
    case sendFile = 4
    case metrics = 5
    case setenv = 6
    case endenv = 7
    case screenshot = 8
    case replayEvents = 9
    case captureEvents = 10
    case invalid = 1000
    case eof = -1
}

private enum InjectionNextResponse: Int32 {
    case platform = 0
    case injected = 1
    case failed = 2
    case tmpPath = 3
    case unhide = 4
    case projectRoot = 5
    case detail = 6
    case bazelTarget = 7
    case executable = 8
    case screenshotData = 9
    case touchEvent = 10
    case replayComplete = 11
    case exit = -1
}

private enum InjectionNextWire {
    static let version: Int32 = 4001

    static func makeSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlError(
                code: "RUNTIME_SOCKET_CREATE_FAILED",
                message: "socket() failed: \(String(cString: strerror(errno)))"
            )
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
        return fd
    }

    static func readExactly(
        _ count: Int,
        from fd: Int32
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0

        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }

            while offset < count {
                let readCount = Darwin.read(
                    fd,
                    base.advanced(by: offset),
                    count - offset
                )

                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw ControlError(
                        code: "RUNTIME_READ_FAILED",
                        message: "read() failed: \(String(cString: strerror(errno)))"
                    )
                }

                if readCount == 0 {
                    throw ControlError(
                        code: "RUNTIME_DISCONNECTED",
                        message: "Injection runtime disconnected."
                    )
                }

                offset += readCount
            }
        }

        return data
    }

    static func writeAll(
        _ data: Data,
        to fd: Int32
    ) throws {
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
                        code: "RUNTIME_WRITE_FAILED",
                        message: "write() failed: \(String(cString: strerror(errno)))"
                    )
                }

                offset += written
            }
        }
    }

    static func readInt(from fd: Int32) throws -> Int32 {
        let data = try readExactly(
            MemoryLayout<Int32>.size,
            from: fd
        )

        var value: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(
                &value,
                base,
                MemoryLayout<Int32>.size
            )
        }
        return value
    }

    static func writeInt(
        _ value: Int32,
        to fd: Int32
    ) throws {
        var value = value
        let data = Data(
            bytes: &value,
            count: MemoryLayout<Int32>.size
        )
        try writeAll(data, to: fd)
    }

    static func readData(from fd: Int32) throws -> Data {
        let length = try readInt(from: fd)
        guard length >= 0 else {
            throw ControlError(
                code: "RUNTIME_PROTOCOL_ERROR",
                message: "Negative payload length: \(length)"
            )
        }
        return try readExactly(Int(length), from: fd)
    }

    static func writeData(
        _ data: Data,
        to fd: Int32
    ) throws {
        guard data.count <= Int(Int32.max) else {
            throw ControlError(
                code: "RUNTIME_PAYLOAD_TOO_LARGE",
                message: "Payload exceeds Int32 protocol length."
            )
        }

        try writeInt(Int32(data.count), to: fd)
        try writeAll(data, to: fd)
    }

    static func readString(from fd: Int32) throws -> String {
        let data = try readData(from: fd)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ControlError(
                code: "RUNTIME_PROTOCOL_ERROR",
                message: "Runtime sent a non-UTF8 string."
            )
        }
        return value
    }

    static func writeString(
        _ value: String,
        to fd: Int32
    ) throws {
        try writeData(Data(value.utf8), to: fd)
    }
}

public struct InjectionRuntimeStatus: Codable, Sendable {
    public let id: String?
    public let connected: Bool
    public let platform: String?
    public let arch: String?
    public let temporaryPath: String?
    public let peerAddress: String?
    public let isLocal: Bool

    public init(
        id: String? = nil,
        connected: Bool,
        platform: String? = nil,
        arch: String? = nil,
        temporaryPath: String? = nil,
        peerAddress: String? = nil,
        isLocal: Bool = true
    ) {
        self.id = id
        self.connected = connected
        self.platform = platform
        self.arch = arch
        self.temporaryPath = temporaryPath
        self.peerAddress = peerAddress
        self.isLocal = isLocal
    }

    public var target: RuntimeTarget? {
        guard let id else { return nil }
        return RuntimeTarget(
            id: id,
            platform: platform,
            arch: arch,
            temporaryPath: temporaryPath,
            peerAddress: peerAddress,
            isLocal: isLocal,
            connected: connected
        )
    }
}

private final class PendingRuntimeInjection {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded: Bool?
    var message: String?
}

private final class PendingRuntimeScreenshot {
    let semaphore = DispatchSemaphore(value: 0)
    var mimeType: String?
    var data: Data?
}

private final class PendingTouchReplay {
    let semaphore = DispatchSemaphore(value: 0)
    var payload: String?
}

private final class InjectionRuntimeClient {
    let id: String
    let peerAddress: String
    let isLocal: Bool

    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private let operationLock = NSLock()

    private var platformValue: String?
    private var archValue: String?
    private var temporaryPathValue: String?
    private var connectedValue = true
    private var pendingInjection: PendingRuntimeInjection?
    private var pendingScreenshot: PendingRuntimeScreenshot?
    private var pendingTouchReplay: PendingTouchReplay?
    private var touchEvents: [String] = []
    private let logStore: AgentLogStore

    init(
        fd: Int32,
        peerAddress: String,
        isLocal: Bool,
        logStore: AgentLogStore
    ) {
        self.id = UUID().uuidString
        self.fd = fd
        self.peerAddress = peerAddress
        self.isLocal = isLocal
        self.logStore = logStore
    }

    deinit {
        Darwin.close(fd)
    }

    func validate(
        xcodePath: String? = nil
    ) throws {
        let version = try InjectionNextWire.readInt(from: fd)
        guard version == InjectionNextWire.version else {
            throw ControlError(
                code: "RUNTIME_VERSION_MISMATCH",
                message: "Expected InjectionNext protocol \(InjectionNextWire.version), got \(version)."
            )
        }

        let key = try InjectionNextWire.readString(from: fd)
        guard key.hasPrefix(NSHomeDirectory()) else {
            throw ControlError(
                code: "RUNTIME_KEY_REJECTED",
                message: "Injection runtime key is outside the current user's home directory."
            )
        }

        try send(
            command: .xcodePath,
            string: xcodePath
                ?? Self.xcodeApplicationPath()
        )
    }

    func setXcodePath(
        _ path: String
    ) throws {
        try send(
            command: .xcodePath,
            string: path
        )
    }

    func processResponses(
        onDisconnect: @escaping () -> Void
    ) {
        defer {
            stateLock.lock()
            connectedValue = false
            let pending = pendingInjection
            let screenshot = pendingScreenshot
            let replay = pendingTouchReplay
            pendingInjection = nil
            pendingScreenshot = nil
            pendingTouchReplay = nil
            stateLock.unlock()

            if let pending {
                pending.succeeded = false
                pending.message = "Injection runtime disconnected."
                pending.semaphore.signal()
            }
            screenshot?.semaphore.signal()
            replay?.semaphore.signal()

            logStore.append(
                "Runtime disconnected: \(id) \(peerAddress)",
                level: "warning"
            )
            onDisconnect()
        }

        do {
            while true {
                let raw = try InjectionNextWire.readInt(from: fd)
                guard let response = InjectionNextResponse(rawValue: raw) else {
                    throw ControlError(
                        code: "RUNTIME_PROTOCOL_ERROR",
                        message: "Unknown InjectionNext response: \(raw)"
                    )
                }

                switch response {
                case .platform:
                    let platform = try InjectionNextWire.readString(from: fd)
                    let arch = try InjectionNextWire.readString(from: fd)
                    updateState {
                        platformValue = platform
                        archValue = arch
                    }

                case .tmpPath:
                    let path = try InjectionNextWire.readString(from: fd)
                    updateState {
                        temporaryPathValue =
                            path.count > 1 && path.hasSuffix("/")
                            ? String(path.dropLast())
                            : path
                    }

                case .injected:
                    completeInjection(
                        succeeded: true,
                        message: "Runtime loaded and patched dylib."
                    )

                case .failed:
                    completeInjection(
                        succeeded: false,
                        message: "Runtime reported injection failure."
                    )

                case .unhide:
                    completeInjection(
                        succeeded: false,
                        message: "Runtime could not load dylib; symbols may need unhiding."
                    )

                case .projectRoot:
                    let value = try InjectionNextWire.readString(from: fd)
                    logStore.append(
                        "Runtime project root: \(value)"
                    )

                case .detail:
                    let value = try InjectionNextWire.readString(from: fd)
                    logStore.append(value, level: "detail")

                case .bazelTarget:
                    let value = try InjectionNextWire.readString(from: fd)
                    logStore.append(
                        "Runtime Bazel target: \(value)"
                    )

                case .executable:
                    let value = try InjectionNextWire.readString(from: fd)
                    logStore.append(
                        "Runtime executable: \(value)"
                    )

                case .touchEvent:
                    let json = try InjectionNextWire.readString(from: fd)
                    stateLock.lock()
                    touchEvents.append(json)
                    if touchEvents.count > 10_000 {
                        touchEvents.removeFirst(
                            touchEvents.count - 10_000
                        )
                    }
                    stateLock.unlock()

                case .replayComplete:
                    let payload = try InjectionNextWire.readString(from: fd)
                    completeTouchReplay(payload)

                case .screenshotData:
                    let mimeType = try InjectionNextWire.readString(from: fd)
                    let data = try InjectionNextWire.readData(from: fd)
                    completeScreenshot(
                        mimeType: mimeType,
                        data: data
                    )

                case .exit:
                    return
                }
            }
        } catch {
            // Disconnect is surfaced through status and any pending command.
        }
    }

    func status() -> InjectionRuntimeStatus {
        stateLock.lock()
        defer { stateLock.unlock() }

        return InjectionRuntimeStatus(
            id: id,
            connected: connectedValue,
            platform: platformValue,
            arch: archValue,
            temporaryPath: temporaryPathValue,
            peerAddress: peerAddress,
            isLocal: isLocal
        )
    }

    func loadDylib(
        sourcePath: String,
        timeout: TimeInterval = 10
    ) -> InjectionResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Dylib does not exist."
            )
        }

        let pending = PendingRuntimeInjection()

        stateLock.lock()
        guard pendingInjection == nil else {
            stateLock.unlock()
            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Another runtime injection is already pending."
            )
        }
        pendingInjection = pending
        stateLock.unlock()

        var localTemporaryDylib: URL?

        do {
            if isLocal {
                guard let tmpPath = status().temporaryPath else {
                    throw ControlError(
                        code: "RUNTIME_HANDSHAKE_INCOMPLETE",
                        message: "Runtime has not reported its temporary path yet."
                    )
                }

                let destinationURL = URL(
                    fileURLWithPath: tmpPath
                )
                .appendingPathComponent(
                    "agent_injection_\(UUID().uuidString).dylib"
                )

                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destinationURL
                )
                localTemporaryDylib = destinationURL

                try send(
                    command: .load,
                    string: destinationURL.path
                )
            } else {
                let data = try Data(
                    contentsOf: sourceURL,
                    options: [.mappedIfSafe]
                )
                try sendRemoteInjection(
                    name: sourceURL.lastPathComponent,
                    data: data
                )
            }
        } catch {
            stateLock.lock()
            if pendingInjection === pending {
                pendingInjection = nil
            }
            stateLock.unlock()

            if let localTemporaryDylib {
                try? FileManager.default.removeItem(
                    at: localTemporaryDylib
                )
            }

            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Unable to send injection dylib: \(error)"
            )
        }

        let waitResult = pending.semaphore.wait(
            timeout: .now() + timeout
        )

        stateLock.lock()
        if pendingInjection === pending {
            pendingInjection = nil
        }
        stateLock.unlock()

        if let localTemporaryDylib {
            try? FileManager.default.removeItem(
                at: localTemporaryDylib
            )
        }

        guard waitResult == .success else {
            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Timed out waiting for runtime injection result."
            )
        }

        return InjectionResult(
            file: sourcePath,
            compiled: true,
            injected: pending.succeeded == true,
            message: pending.message
        )
    }

    func captureTouchEvents() throws {
        try send(
            command: .captureEvents,
            string: nil
        )
    }

    func drainTouchEvents() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }

        let drained = touchEvents
        touchEvents.removeAll(
            keepingCapacity: true
        )
        return drained
    }

    func replayTouchEvents(
        _ payload: String,
        timeout: TimeInterval = 15
    ) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }

        let pending = PendingTouchReplay()

        stateLock.lock()
        guard pendingTouchReplay == nil else {
            stateLock.unlock()
            return false
        }
        pendingTouchReplay = pending
        stateLock.unlock()

        do {
            try send(
                command: .replayEvents,
                string: payload
            )
        } catch {
            stateLock.lock()
            if pendingTouchReplay === pending {
                pendingTouchReplay = nil
            }
            stateLock.unlock()
            return false
        }

        let wait = pending.semaphore.wait(
            timeout: .now() + timeout
        )

        stateLock.lock()
        if pendingTouchReplay === pending {
            pendingTouchReplay = nil
        }
        stateLock.unlock()

        return wait == .success
    }

    func requestScreenshot(
        timeout: TimeInterval = 10
    ) -> (mimeType: String, data: Data)? {
        operationLock.lock()
        defer { operationLock.unlock() }

        let pending = PendingRuntimeScreenshot()

        stateLock.lock()
        guard connectedValue, pendingScreenshot == nil else {
            stateLock.unlock()
            return nil
        }
        pendingScreenshot = pending
        stateLock.unlock()

        do {
            try send(
                command: .screenshot,
                string: nil
            )
        } catch {
            stateLock.lock()
            if pendingScreenshot === pending {
                pendingScreenshot = nil
            }
            stateLock.unlock()
            return nil
        }

        let wait = pending.semaphore.wait(
            timeout: .now() + timeout
        )

        stateLock.lock()
        if pendingScreenshot === pending {
            pendingScreenshot = nil
        }
        stateLock.unlock()

        guard wait == .success,
              let mimeType = pending.mimeType,
              !mimeType.isEmpty,
              let data = pending.data,
              !data.isEmpty else {
            return nil
        }

        return (mimeType, data)
    }

    func setEnvironment(
        _ values: [String: String?]
    ) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        for name in values.keys.sorted() {
            try InjectionNextWire.writeInt(
                InjectionNextCommand.setenv.rawValue,
                to: fd
            )
            try InjectionNextWire.writeString(
                name,
                to: fd
            )
            let value = values[name] ?? nil
            try InjectionNextWire.writeString(
                value ?? "__NULL__",
                to: fd
            )
        }

        try InjectionNextWire.writeInt(
            InjectionNextCommand.endenv.rawValue,
            to: fd
        )
    }

    private func sendRemoteInjection(
        name: String,
        data: Data
    ) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        try InjectionNextWire.writeInt(
            InjectionNextCommand.inject.rawValue,
            to: fd
        )
        try InjectionNextWire.writeString(
            name,
            to: fd
        )
        try InjectionNextWire.writeData(
            data,
            to: fd
        )

        logStore.append(
            "Sent \(data.count) bytes to device target \(id)"
        )
    }

    private func send(
        command: InjectionNextCommand,
        string: String?
    ) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        try InjectionNextWire.writeInt(
            command.rawValue,
            to: fd
        )
        if let string {
            try InjectionNextWire.writeString(
                string,
                to: fd
            )
        }
    }

    private func updateState(
        _ mutate: () -> Void
    ) {
        stateLock.lock()
        mutate()
        stateLock.unlock()
    }

    private func completeInjection(
        succeeded: Bool,
        message: String
    ) {
        stateLock.lock()
        let pending = pendingInjection
        pendingInjection = nil
        stateLock.unlock()

        guard let pending else { return }
        pending.succeeded = succeeded
        pending.message = message
        pending.semaphore.signal()
    }

    private func completeTouchReplay(
        _ payload: String
    ) {
        stateLock.lock()
        let pending = pendingTouchReplay
        pendingTouchReplay = nil
        stateLock.unlock()

        guard let pending else { return }
        pending.payload = payload
        pending.semaphore.signal()
    }

    private func completeScreenshot(
        mimeType: String,
        data: Data
    ) {
        stateLock.lock()
        let pending = pendingScreenshot
        pendingScreenshot = nil
        stateLock.unlock()

        guard let pending else { return }
        pending.mimeType = mimeType
        pending.data = data
        pending.semaphore.signal()
    }

    private static func xcodeApplicationPath() -> String {
        if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           let range = developerDir.range(of: ".app/Contents/Developer") {
            return String(
                developerDir[..<range.upperBound]
            )
            .replacingOccurrences(
                of: "/Contents/Developer",
                with: ""
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let developerDir = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let developerDir,
               developerDir.hasSuffix("/Contents/Developer") {
                return String(
                    developerDir.dropLast("/Contents/Developer".count)
                )
            }
        } catch {
            // Fall through to the standard location.
        }

        return "/Applications/Xcode.app"
    }
}

public final class InjectionNextRuntimeServer {
    public let port: UInt16
    public let devicesEnabled: Bool

    private let queue = DispatchQueue(
        label: "agentInjectionIII.runtime-server",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private let logStore: AgentLogStore
    private let discovery: InjectionDeviceDiscovery?
    private var selectedXcodePath: String?

    private var listenerFD: Int32 = -1
    private var clients: [String: InjectionRuntimeClient] = [:]
    private var clientOrder: [String] = []

    public init(
        port: UInt16 = 8887,
        devicesEnabled: Bool = false,
        logStore: AgentLogStore = AgentLogStore(),
        xcodePath: String? = nil
    ) {
        self.port = port
        self.devicesEnabled = devicesEnabled
        self.logStore = logStore
        self.selectedXcodePath = xcodePath
        self.discovery = devicesEnabled
            ? InjectionDeviceDiscovery(port: port)
            : nil
    }

    deinit {
        if listenerFD >= 0 {
            Darwin.close(listenerFD)
        }
        discovery?.stop()
    }

    public func start() throws {
        guard listenerFD < 0 else { return }

        let fd = try InjectionNextWire.makeSocket()
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
                code: "RUNTIME_BIND_FAILED",
                message: "Unable to bind \(host):\(port): \(String(cString: strerror(errno)))"
            )
        }

        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw ControlError(
                code: "RUNTIME_LISTEN_FAILED",
                message: "listen() failed: \(String(cString: strerror(errno)))"
            )
        }

        listenerFD = fd

        if devicesEnabled {
            try discovery?.start()
            logStore.append(
                "Device injection enabled; TCP/UDP listening on :\(port)."
            )
        }

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func setXcodePath(
        _ path: String
    ) {
        stateLock.lock()
        selectedXcodePath = path
        let currentClients = clientOrder.compactMap {
            clients[$0]
        }
        stateLock.unlock()

        for client in currentClients {
            do {
                try client.setXcodePath(path)
            } catch {
                logStore.append(
                    "Unable to update Xcode path for target \(client.id): \(error)",
                    level: "warning"
                )
            }
        }
    }

    public func status(
        target id: String? = nil
    ) -> InjectionRuntimeStatus {
        guard let client = client(target: id) else {
            return InjectionRuntimeStatus(
                connected: false,
                isLocal: true
            )
        }
        return client.status()
    }

    public func targets() -> [RuntimeTarget] {
        stateLock.lock()
        let ordered = clientOrder.compactMap {
            clients[$0]
        }
        stateLock.unlock()

        return ordered.compactMap {
            $0.status().target
        }
    }

    public func loadDylib(
        path: String,
        target id: String? = nil
    ) -> InjectionResult {
        guard let client = client(target: id) else {
            return InjectionResult(
                file: path,
                compiled: true,
                injected: false,
                message: id == nil
                    ? "No InjectionNext runtime is connected."
                    : "Target not found: \(id!)"
            )
        }

        return client.loadDylib(
            sourcePath: path
        )
    }

    public func requestScreenshot(
        target id: String? = nil
    ) -> (mimeType: String, data: Data)? {
        client(target: id)?
            .requestScreenshot()
    }

    public func captureTouchEvents(
        target id: String? = nil
    ) -> Result<TouchResult, ControlError> {
        guard let client = client(target: id) else {
            return .failure(
                ControlError(
                    code: "TARGET_NOT_FOUND",
                    message: id == nil
                        ? "No connected runtime target."
                        : "Target not found: \(id!)"
                )
            )
        }

        do {
            try client.captureTouchEvents()
            return .success(
                TouchResult(
                    target: client.id,
                    events: []
                )
            )
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(
                ControlError(
                    code: "TOUCH_CAPTURE_FAILED",
                    message: String(describing: error)
                )
            )
        }
    }

    public func drainTouchEvents(
        target id: String? = nil
    ) -> Result<TouchResult, ControlError> {
        guard let client = client(target: id) else {
            return .failure(
                ControlError(
                    code: "TARGET_NOT_FOUND",
                    message: id == nil
                        ? "No connected runtime target."
                        : "Target not found: \(id!)"
                )
            )
        }

        return .success(
            TouchResult(
                target: client.id,
                events: client.drainTouchEvents()
            )
        )
    }

    public func replayTouchEvents(
        _ payload: String,
        target id: String? = nil
    ) -> Result<TouchResult, ControlError> {
        guard let client = client(target: id) else {
            return .failure(
                ControlError(
                    code: "TARGET_NOT_FOUND",
                    message: id == nil
                        ? "No connected runtime target."
                        : "Target not found: \(id!)"
                )
            )
        }

        guard client.replayTouchEvents(payload) else {
            return .failure(
                ControlError(
                    code: "TOUCH_REPLAY_FAILED",
                    message: "Runtime did not confirm touch replay."
                )
            )
        }

        var replayed: Int?
        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(
                with: data
           ) as? [String: Any],
           let events = object["events"] as? [Any] {
            replayed = events.count
        }

        return .success(
            TouchResult(
                target: client.id,
                replayed: replayed
            )
        )
    }

    public func setEnvironment(
        _ values: [String: String?],
        target id: String? = nil
    ) -> Result<OperationResult, ControlError> {
        let selected: [InjectionRuntimeClient]

        stateLock.lock()
        if let id {
            if let client = clients[id] {
                selected = [client]
            } else {
                selected = []
            }
        } else {
            selected = clientOrder.compactMap {
                clients[$0]
            }
        }
        stateLock.unlock()

        guard !selected.isEmpty else {
            return .failure(
                ControlError(
                    code: "TARGET_NOT_FOUND",
                    message: id == nil
                        ? "No connected runtime target."
                        : "Target not found: \(id!)"
                )
            )
        }

        do {
            for client in selected {
                try client.setEnvironment(values)
            }

            return .success(
                OperationResult(
                    message: "Updated \(values.count) Injection runtime setting(s) on \(selected.count) target(s)."
                )
            )
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(
                ControlError(
                    code: "RUNTIME_ENV_FAILED",
                    message: String(describing: error)
                )
            )
        }
    }

    public func logs(
        since: Double?,
        limit: Int?
    ) -> LogsResult {
        logStore.get(
            since: since,
            limit: limit
        )
    }

    public func clearLogs() -> LogsResult {
        logStore.clear()
    }

    private func client(
        target id: String?
    ) -> InjectionRuntimeClient? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let id {
            return clients[id]
        }

        for id in clientOrder.reversed() {
            if let client = clients[id],
               client.status().connected {
                return client
            }
        }

        return nil
    }

    private func acceptLoop() {
        while listenerFD >= 0 {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(
                MemoryLayout<sockaddr_storage>.size
            )

            let fd = withUnsafeMutablePointer(
                to: &peer
            ) {
                $0.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.accept(
                        listenerFD,
                        $0,
                        &peerLength
                    )
                }
            }

            if fd < 0 {
                if errno == EINTR { continue }
                continue
            }

            let peerInfo = Self.peerInfo(peer)
            let client = InjectionRuntimeClient(
                fd: fd,
                peerAddress: peerInfo.address,
                isLocal: peerInfo.local,
                logStore: logStore
            )

            stateLock.lock()
            let xcodePath = selectedXcodePath
            stateLock.unlock()

            do {
                try client.validate(
                    xcodePath: xcodePath
                )
            } catch {
                logStore.append(
                    "Rejected runtime connection from \(peerInfo.address): \(error)",
                    level: "warning"
                )
                continue
            }

            stateLock.lock()
            clients[client.id] = client
            clientOrder.removeAll {
                $0 == client.id
            }
            clientOrder.append(client.id)
            stateLock.unlock()

            logStore.append(
                "Runtime connected: target=\(client.id) peer=\(peerInfo.address) local=\(peerInfo.local)"
            )

            queue.async { [weak self, weak client] in
                guard let self, let client else { return }
                client.processResponses {
                    self.stateLock.lock()
                    self.clients.removeValue(
                        forKey: client.id
                    )
                    self.clientOrder.removeAll {
                        $0 == client.id
                    }
                    self.stateLock.unlock()
                }
            }
        }
    }

    private static func peerInfo(
        _ storage: sockaddr_storage
    ) -> (address: String, local: Bool) {
        var storage = storage
        var host = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )

        let length: socklen_t
        switch Int32(storage.ss_family) {
        case AF_INET:
            length = socklen_t(
                MemoryLayout<sockaddr_in>.size
            )
        case AF_INET6:
            length = socklen_t(
                MemoryLayout<sockaddr_in6>.size
            )
        default:
            return ("unknown", false)
        }

        let result = withUnsafePointer(
            to: &storage
        ) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getnameinfo(
                    $0,
                    length,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }

        guard result == 0 else {
            return ("unknown", false)
        }

        let address = String(cString: host)
        let local =
            address == "127.0.0.1" ||
            address == "::1"

        return (address, local)
    }
}

public final class InjectionNextRuntimeBackend: InjectionBackend {
    public let name = "injectionnext-headless"

    private let runtimeServer: InjectionNextRuntimeServer
    private let traceServer: AgentTraceServer
    private let projectRoot: String?
    private let compiler: BuildLogCompiler
    private lazy var compilerInterception =
        CompilerInterceptionManager(compiler: compiler)
    private let codeSigningIdentity: String?
    private let swiftUIPreparer = SwiftUIPreparer()
    private let projectReorderer = ProjectReorderer()
    private let eventStore = InjectionEventStore()
    private let backendStateLock = NSLock()
    private var lastErrorValue: ControlError?
    private var lastSourceValue: String?

    public init(
        runtimeServer: InjectionNextRuntimeServer,
        traceServer: AgentTraceServer,
        projectRoot: String? = nil,
        derivedDataRoot: String? = nil,
        codeSigningIdentity: String? = nil,
        xcodePath: String? = nil,
        deviceTesting: Bool = false,
        deviceLibraries: [String] = [
            "-framework", "XCTest",
            "-lXCTestSwiftSupport"
        ]
    ) {
        self.runtimeServer = runtimeServer
        self.traceServer = traceServer
        self.projectRoot = projectRoot
        self.codeSigningIdentity = codeSigningIdentity
        self.compiler = BuildLogCompiler(
            projectRoot: projectRoot,
            derivedDataRoot: derivedDataRoot,
            xcodePath: xcodePath,
            deviceTesting: deviceTesting,
            deviceLibraries: deviceLibraries
        )

        if let xcodePath {
            runtimeServer.setXcodePath(
                xcodePath
            )
        }
    }

    public func status() -> BackendStatus {
        let runtime = runtimeServer.status()

        return BackendStatus(
            name: name,
            ready: runtime.connected,
            appConnected: runtime.connected,
            capabilities: [
                "status",
                "diagnostics",
                "source-inject",
                "load-dylib",
                "swift",
                "objc",
                "objc++",
                "xcode-build-log",
                "screenshot",
                "trace",
                "targets",
                "device-injection",
                "touch-capture",
                "touch-replay",
                "logs",
                "unhide-symbols",
                "swiftui-prepare",
                "xcode-selection",
                "last-error",
                "lifecycle-events",
                "device-testing",
                "runtime-env",
                "call-order",
                "instance-counts",
                "compiler-interception",
                "xctest-results",
                "reorder-project",
                "xprobe",
                "eval"
            ],
            platform: runtime.platform,
            arch: runtime.arch,
            temporaryPath: runtime.temporaryPath,
            detail: runtime.connected
                ? "InjectionNext runtime connected; explicit source injection is available."
                : "Listening for InjectionNext runtime on 127.0.0.1:\(runtimeServer.port)."
        )
    }

    public func targets() -> TargetsResult {
        TargetsResult(
            targets: runtimeServer.targets()
        )
    }

    public func inject(
        files: [String],
        target: String?
    ) -> BackendInjectionResponse {
        clearLastError()

        let runtime = runtimeServer.status(
            target: target
        )

        guard runtime.connected else {
            let error = ControlError(
                code: "RUNTIME_NOT_CONNECTED",
                message: "Launch a DEBUG app containing the InjectionNext client runtime."
            )
            let firstSource = files.first.map {
                normalize(path: $0)
            }
            record(
                error: error,
                source: firstSource
            )
            eventStore.append(
                phase: "failed",
                source: firstSource,
                target: target,
                message: error.message
            )
            return BackendInjectionResponse(
                results: files.map {
                    InjectionResult(
                        file: normalize(path: $0),
                        compiled: false,
                        injected: false,
                        message: "No InjectionNext runtime is connected."
                    )
                },
                error: error
            )
        }

        guard let platform = runtime.platform,
              let arch = runtime.arch else {
            let error = ControlError(
                code: "RUNTIME_HANDSHAKE_INCOMPLETE",
                message: "Runtime is connected but platform metadata is not ready."
            )
            let firstSource = files.first.map {
                normalize(path: $0)
            }
            record(
                error: error,
                source: firstSource
            )
            eventStore.append(
                phase: "failed",
                source: firstSource,
                target: runtime.id ?? target,
                message: error.message
            )
            return BackendInjectionResponse(
                results: files.map {
                    InjectionResult(
                        file: normalize(path: $0),
                        compiled: false,
                        injected: false,
                        message: error.message
                    )
                },
                error: error
            )
        }

        var results: [InjectionResult] = []
        var firstError: ControlError?

        for input in files {
            let source = normalize(path: input)
            let targetID = runtime.id ?? target

            eventStore.append(
                phase: "compiling",
                source: source,
                target: targetID
            )

            switch compiler.compileAndLink(
                source: source,
                platform: platform,
                arch: arch
            ) {
            case .failure(let error):
                if firstError == nil {
                    firstError = error
                    record(
                        error: error,
                        source: source
                    )
                }
                eventStore.append(
                    phase: "failed",
                    source: source,
                    target: targetID,
                    message: error.message
                )
                results.append(
                    InjectionResult(
                        file: source,
                        compiled: false,
                        injected: false,
                        message: error.message
                    )
                )

            case .success(let artifact):
                eventStore.append(
                    phase: "compiled",
                    source: source,
                    target: targetID,
                    compileMilliseconds: artifact.compileMilliseconds,
                    linkMilliseconds: artifact.linkMilliseconds
                )
                if platform == "iPhoneOS" ||
                   platform == "AppleTVOS" ||
                   platform == "XROS" {
                    eventStore.append(
                        phase: "signing",
                        source: source,
                        target: targetID
                    )

                    guard let identity = codeSigningIdentity,
                          !identity.isEmpty else {
                        compiler.remove(artifact)
                        let error = ControlError(
                            code: "CODESIGN_IDENTITY_REQUIRED",
                            message: "Device injection requires --codesign-identity matching the app's expanded code signing identity."
                        )
                        if firstError == nil {
                            firstError = error
                            record(
                                error: error,
                                source: source
                            )
                        }
                        eventStore.append(
                            phase: "failed",
                            source: source,
                            target: targetID,
                            message: error.message,
                            compileMilliseconds: artifact.compileMilliseconds,
                            linkMilliseconds: artifact.linkMilliseconds
                        )
                        results.append(
                            InjectionResult(
                                file: source,
                                compiled: true,
                                injected: false,
                                compileMilliseconds: artifact.compileMilliseconds,
                                linkMilliseconds: artifact.linkMilliseconds,
                                message: error.message
                            )
                        )
                        continue
                    }

                    switch compiler.codesign(
                        artifact,
                        identity: identity
                    ) {
                    case .success:
                        break
                    case .failure(let error):
                        compiler.remove(artifact)
                        if firstError == nil {
                            firstError = error
                            record(
                                error: error,
                                source: source
                            )
                        }
                        eventStore.append(
                            phase: "failed",
                            source: source,
                            target: targetID,
                            message: error.message,
                            compileMilliseconds: artifact.compileMilliseconds,
                            linkMilliseconds: artifact.linkMilliseconds
                        )
                        results.append(
                            InjectionResult(
                                file: source,
                                compiled: true,
                                injected: false,
                                compileMilliseconds: artifact.compileMilliseconds,
                                linkMilliseconds: artifact.linkMilliseconds,
                                message: error.message
                            )
                        )
                        continue
                    }
                }

                eventStore.append(
                    phase: "injecting",
                    source: source,
                    target: targetID,
                    compileMilliseconds: artifact.compileMilliseconds,
                    linkMilliseconds: artifact.linkMilliseconds
                )

                let runtimeResult = runtimeServer.loadDylib(
                    path: artifact.dylib,
                    target: target
                )
                compiler.remove(artifact)

                let detail = runtimeResult.message

                if !runtimeResult.injected,
                   firstError == nil {
                    let error = ControlError(
                        code: "DYLIB_INJECTION_FAILED",
                        message: runtimeResult.message
                            ?? "Runtime failed to inject compiled dylib."
                    )
                    firstError = error
                    record(
                        error: error,
                        source: source
                    )
                }

                eventStore.append(
                    phase: runtimeResult.injected
                        ? "injected"
                        : "failed",
                    source: source,
                    target: targetID,
                    message: runtimeResult.message,
                    compileMilliseconds: artifact.compileMilliseconds,
                    linkMilliseconds: artifact.linkMilliseconds
                )

                results.append(
                    InjectionResult(
                        file: source,
                        compiled: true,
                        injected: runtimeResult.injected,
                        compileMilliseconds: artifact.compileMilliseconds,
                        linkMilliseconds: artifact.linkMilliseconds,
                        message: detail
                    )
                )
            }
        }

        return BackendInjectionResponse(
            results: results,
            error: firstError
        )
    }

    public func loadDylib(
        path: String,
        target: String?
    ) -> BackendInjectionResponse {
        let normalized = normalize(path: path)
        let result = runtimeServer.loadDylib(
            path: normalized,
            target: target
        )

        let error: ControlError?
        if result.injected {
            error = nil
            clearLastError()
        } else {
            let failure = ControlError(
                code: "DYLIB_INJECTION_FAILED",
                message: result.message
                    ?? "Runtime failed to inject dylib."
            )
            error = failure
            record(
                error: failure,
                source: normalized
            )
        }

        return BackendInjectionResponse(
            results: [result],
            error: error
        )
    }

    public func diagnostics(
        limit: Int?
    ) -> DiagnosticsResult {
        DiagnosticsResult(
            status: status(),
            targets: targets(),
            trace: traceServer.status(),
            compilerState: compilerState(),
            doctor: doctor(path: nil),
            logs: logs(
                since: nil,
                limit: limit
            ),
            events: eventStore.snapshot(
                limit: limit
            ),
            lastError: lastError()
        )
    }

    public func screenshot(
        path: String?,
        target: String?
    ) -> Result<ScreenshotResult, ControlError> {
        guard let captured = runtimeServer.requestScreenshot(
            target: target
        ) else {
            return .failure(
                ControlError(
                    code: "SCREENSHOT_FAILED",
                    message: "Unable to capture screenshot. Ensure the DEBUG app runtime is connected and has a visible window."
                )
            )
        }

        let outputPath: String
        if let path, !path.isEmpty {
            outputPath = normalize(path: path)
        } else {
            outputPath = URL(
                fileURLWithPath: NSTemporaryDirectory()
            )
            .appendingPathComponent(
                "agentInjectionIII-\(UUID().uuidString).png"
            )
            .path
        }

        let outputURL = URL(fileURLWithPath: outputPath)

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try captured.data.write(
                to: outputURL,
                options: .atomic
            )
        } catch {
            return .failure(
                ControlError(
                    code: "SCREENSHOT_WRITE_FAILED",
                    message: "Unable to write screenshot to \(outputPath): \(error)"
                )
            )
        }

        return .success(
            ScreenshotResult(
                path: outputPath,
                mimeType: captured.mimeType,
                byteCount: captured.data.count
            )
        )
    }

    public func touchCapture(
        target: String?
    ) -> Result<TouchResult, ControlError> {
        runtimeServer.captureTouchEvents(
            target: target
        )
    }

    public func touchRead(
        target: String?
    ) -> Result<TouchResult, ControlError> {
        runtimeServer.drainTouchEvents(
            target: target
        )
    }

    public func touchReplay(
        payload: String,
        target: String?
    ) -> Result<TouchResult, ControlError> {
        runtimeServer.replayTouchEvents(
            payload,
            target: target
        )
    }

    public func logs(
        since: Double?,
        limit: Int?
    ) -> LogsResult {
        runtimeServer.logs(
            since: since,
            limit: limit
        )
    }

    public func clearLogs() -> LogsResult {
        runtimeServer.clearLogs()
    }

    public func unhideSymbols()
        -> Result<OperationResult, ControlError> {
        #if DEBUG
        guard let intermediates =
                compiler.intermediatesDirectory() else {
            return .failure(
                ControlError(
                    code: "UNHIDE_INTERMEDIATES_NOT_FOUND",
                    message: "Unable to locate Build/Intermediates.noindex. Build the project once in Xcode first."
                )
            )
        }

        do {
            try Unhider.unhideAllObjects(
                intermediates: intermediates
            )
            return .success(
                OperationResult(
                    message: "Swift default-argument symbols were exported under \(intermediates.path). Restart the app before injecting code that depends on those symbols."
                )
            )
        } catch {
            return .failure(
                ControlError(
                    code: "UNHIDE_FAILED",
                    message: String(describing: error)
                )
            )
        }
        #else
        return .failure(
            ControlError(
                code: "UNHIDE_DEBUG_ONLY",
                message: "Upstream InjectionLite Unhider is only available in Debug Swift Package builds."
            )
        )
        #endif
    }

    public func prepareSwiftUISource(
        path: String
    ) -> Result<OperationResult, ControlError> {
        let source = normalize(path: path)

        guard source.hasSuffix(".swift"),
              FileManager.default.fileExists(
                atPath: source
              ) else {
            return .failure(
                ControlError(
                    code: "SWIFTUI_SOURCE_NOT_FOUND",
                    message: "Swift source not found: \(source)"
                )
            )
        }

        do {
            let result = try swiftUIPreparer
                .prepareSource(source)

            return .success(
                OperationResult(
                    message: result.changes == 0
                        ? "No SwiftUI injection edits were needed for \(source)."
                        : "Applied \(result.changes) SwiftUI injection edit(s) to \(source)."
                )
            )
        } catch {
            return .failure(
                ControlError(
                    code: "SWIFTUI_PREPARE_FAILED",
                    message: String(describing: error)
                )
            )
        }
    }

    public func prepareSwiftUIProject()
        -> Result<OperationResult, ControlError> {
        let sources = compiler.knownSwiftSources()

        guard !sources.isEmpty else {
            return .failure(
                ControlError(
                    code: "SWIFTUI_PROJECT_SOURCES_NOT_FOUND",
                    message: "No compiled Swift sources were recovered from Xcode build logs. Build the target once first."
                )
            )
        }

        let result = swiftUIPreparer
            .prepareProject(
                sources: sources
            )

        return .success(
            OperationResult(
                message: "Applied \(result.changes) SwiftUI injection edit(s) across \(result.filesEdited) of \(sources.count) compiled Swift file(s)."
            )
        )
    }

    public func setXcodePath(
        path: String
    ) -> Result<OperationResult, ControlError> {
        let expanded = NSString(
            string: path
        ).expandingTildeInPath
        let developer = URL(
            fileURLWithPath: expanded
        )
        .appendingPathComponent(
            "Contents/Developer"
        )
        .path

        guard FileManager.default
                .fileExists(atPath: developer) else {
            return .failure(
                ControlError(
                    code: "XCODE_NOT_FOUND",
                    message: "Xcode.app not found or invalid: \(expanded)"
                )
            )
        }

        compiler.setXcodePath(expanded)
        runtimeServer.setXcodePath(expanded)

        return .success(
            OperationResult(
                message: "Selected Xcode: \(expanded)"
            )
        )
    }

    public func launchXcode()
        -> Result<OperationResult, ControlError> {
        guard let xcode = compiler.xcodePath(),
              FileManager.default.fileExists(
                atPath: xcode
              ) else {
            return .failure(
                ControlError(
                    code: "XCODE_NOT_FOUND",
                    message: "No valid Xcode path is selected."
                )
            )
        }

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/open"
        )
        process.arguments = [xcode]

        do {
            try process.run()
            return .success(
                OperationResult(
                    message: "Launched Xcode: \(xcode)"
                )
            )
        } catch {
            return .failure(
                ControlError(
                    code: "XCODE_LAUNCH_FAILED",
                    message: String(describing: error)
                )
            )
        }
    }

    public func lastError() -> LastErrorResult {
        backendStateLock.lock()
        defer { backendStateLock.unlock() }

        return LastErrorResult(
            source: lastSourceValue,
            error: lastErrorValue
        )
    }

    public func events(
        limit: Int?
    ) -> InjectionEventsResult {
        eventStore.drain(limit: limit)
    }

    public func clearEvents()
        -> InjectionEventsResult {
        eventStore.clear()
    }

    public func setRuntimeEnvironment(
        _ values: [String: String?],
        target: String?
    ) -> Result<OperationResult, ControlError> {
        let invalid = values.keys.filter {
            !$0.hasPrefix("INJECTION_")
        }

        guard invalid.isEmpty else {
            return .failure(
                ControlError(
                    code: "RUNTIME_ENV_NOT_ALLOWED",
                    message: "Only INJECTION_* runtime settings are allowed: \(invalid.joined(separator: ", "))"
                )
            )
        }

        return runtimeServer.setEnvironment(
            values,
            target: target
        )
    }

    public func compilerState() -> CompilerStateResult {
        compilerInterception.state()
    }

    public func setCompilerInterception(
        enabled: Bool
    ) -> Result<CompilerStateResult, ControlError> {
        compilerInterception.setEnabled(enabled)
    }

    public func profileSnapshot(
        limit: Int?
    ) -> Result<ProfileResult, ControlError> {
        traceServer.profileSnapshot(
            limit: limit
        )
    }

    public func traceStart(
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        traceServer.startTrace(filter: filter)
    }

    public func traceScope(
        scope: String,
        name: String?,
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        let allowed = Set([
            "frameworks",
            "uikit",
            "swiftui",
            "framework",
            "package",
            "main-all"
        ])

        guard allowed.contains(scope) else {
            return .failure(
                ControlError(
                    code: "TRACE_SCOPE_INVALID",
                    message: "Unsupported trace scope: \(scope)"
                )
            )
        }

        return traceServer.startTraceScope(
            scope: scope,
            name: name,
            filter: filter
        )
    }

    public func callOrder()
        -> Result<CallOrderResult, ControlError> {
        traceServer.callOrderSnapshot()
    }

    public func instancesStart()
        -> Result<InstanceCountsResult, ControlError> {
        traceServer.instancesStart()
    }

    public func instancesRead()
        -> Result<InstanceCountsResult, ControlError> {
        traceServer.instancesRead()
    }

    public func instancesStop()
        -> Result<InstanceCountsResult, ControlError> {
        traceServer.instancesStop()
    }

    public func testResults(
        limit: Int?
    ) -> TestResultsResult {
        traceServer.injectedTestResults(
            limit: limit
        )
    }

    public func clearTestResults()
        -> TestResultsResult {
        traceServer.clearInjectedTestResults()
    }

    public func reorderProject(
        path: String?,
        apply: Bool
    ) -> Result<ProjectReorderPlan, ControlError> {
        switch traceServer.callOrderSnapshot() {
        case .failure(let error):
            return .failure(error)

        case .success(let order):
            return projectReorderer.reorder(
                project: path,
                projectRoot: projectRoot,
                signatures: order.signatures,
                apply: apply
            )
        }
    }

    public func xprobeSearch(
        pattern: String?
    ) -> Result<XprobeResult, ControlError> {
        traceServer.xprobeSearch(
            pattern: pattern
        )
    }

    public func xprobeInspect(
        objectID: Int
    ) -> Result<XprobeResult, ControlError> {
        traceServer.xprobeInspect(
            objectID: objectID
        )
    }

    public func eval(
        objectID: Int,
        code: String
    ) -> Result<EvalResult, ControlError> {
        traceServer.eval(
            objectID: objectID,
            code: code
        )
    }

    public func traceStop()
        -> Result<TraceResult, ControlError> {
        traceServer.stopTrace()
    }

    public func traceRead(
        limit: Int?
    ) -> Result<TraceResult, ControlError> {
        .success(
            traceServer.readTrace(limit: limit)
        )
    }

    public func doctor(path: String?) -> DoctorReport {
        let runtime = runtimeServer.status()
        let normalizedSource =
            path.map { normalize(path: $0) }
        let compilerDiagnostics = compiler.diagnostics(
            source: normalizedSource,
            platform: runtime.platform
        )
        let buildSystem = compiler.buildSystem(
            for: normalizedSource
        )

        var checks = [DoctorCheck]()

        checks.append(
            DoctorCheck(
                name: "build_system",
                state: .pass,
                message: "Compiler provider: \(buildSystem)."
            )
        )

        let xcode = compiler.xcodePath()
        checks.append(
            DoctorCheck(
                name: "xcode",
                state: xcode == nil ? .fail : .pass,
                message: xcode.map {
                    "Selected Xcode application: \($0)"
                } ?? "No usable Xcode application is selected."
            )
        )

        if let projectRoot {
            let expandedProjectRoot = NSString(
                string: projectRoot
            ).expandingTildeInPath
            let exists = FileManager.default.fileExists(
                atPath: expandedProjectRoot
            )
            checks.append(
                DoctorCheck(
                    name: "project",
                    state: exists ? .pass : .fail,
                    message: exists
                        ? "Project root exists: \(expandedProjectRoot)"
                        : "Project root does not exist: \(expandedProjectRoot)"
                )
            )
        } else {
            checks.append(
                DoctorCheck(
                    name: "project",
                    state: .warning,
                    message: "No --project root was supplied; absolute source paths are recommended."
                )
            )
        }

        if buildSystem == "bazel" {
            checks.append(
                DoctorCheck(
                    name: "build_logs",
                    state: .pass,
                    message: "Bazel aquery compiler provider is active; Xcode .xcactivitylog files are optional."
                )
            )
        } else {
            checks.append(
                DoctorCheck(
                    name: "build_logs",
                    state: compilerDiagnostics.buildLogCount > 0
                        ? .pass
                        : .fail,
                    message: compilerDiagnostics.buildLogCount > 0
                        ? "Found \(compilerDiagnostics.buildLogCount) Xcode build log(s). Newest: \(compilerDiagnostics.newestBuildLog ?? "unknown")"
                        : "No .xcactivitylog files found under \(compilerDiagnostics.derivedDataRoot). Build the app once in Xcode."
                )
            )
        }

        checks.append(
            DoctorCheck(
                name: "runtime_connection",
                state: runtime.connected ? .pass : .fail,
                message: runtime.connected
                    ? "Injection runtime is connected."
                    : "No InjectionNext-compatible runtime is connected to 127.0.0.1:\(runtimeServer.port)."
            )
        )

        if runtime.connected {
            let metadataReady =
                runtime.platform != nil &&
                runtime.arch != nil &&
                runtime.temporaryPath != nil

            checks.append(
                DoctorCheck(
                    name: "runtime_handshake",
                    state: metadataReady ? .pass : .fail,
                    message: metadataReady
                        ? "Runtime platform=\(runtime.platform!), arch=\(runtime.arch!), tmp=\(runtime.temporaryPath!)"
                        : "Runtime connected but platform/architecture/temp-path handshake is incomplete."
                )
            )
        }

        let localRuntime = NSString(
            string: "~/.agentInjectionIII/runtime/simulator/iOSInjection.bundle"
        ).expandingTildeInPath
        let runtimeInstalled = FileManager.default.fileExists(
            atPath: localRuntime
        )
        checks.append(
            DoctorCheck(
                name: "local_runtime_bundle",
                state: runtimeInstalled ? .pass : .warning,
                message: runtimeInstalled
                    ? "Local runtime bundle installed: \(localRuntime)"
                    : "Local runtime bundle not found at \(localRuntime). Run scripts/install-runtime.sh if this Mac should use agent mode."
            )
        )

        let trace = traceServer.status()
        checks.append(
            DoctorCheck(
                name: "trace_bridge",
                state: trace.connected ? .pass : .warning,
                message: trace.connected
                    ? "AgentTraceBridge is connected on 127.0.0.1:\(traceServer.port)."
                    : "AgentTraceBridge is not connected. Injection still works, but trace start/read/stop will be unavailable."
            )
        )

        if let source = compilerDiagnostics.source {
            checks.append(
                DoctorCheck(
                    name: "source",
                    state: compilerDiagnostics.sourceExists == true
                        ? .pass
                        : .fail,
                    message: compilerDiagnostics.sourceExists == true
                        ? "Source exists: \(source)"
                        : "Source does not exist: \(source)"
                )
            )

            if compilerDiagnostics.sourceExists == true {
                checks.append(
                    DoctorCheck(
                        name: "compile_command",
                        state: compilerDiagnostics.compileCommandFound == true
                            ? .pass
                            : .fail,
                        message: compilerDiagnostics.compileCommandFound == true
                            ? "Found a matching \(buildSystem) compiler command for this source."
                            : (buildSystem == "bazel"
                                ? "No matching Bazel compiler command found. Verify bazel/bazelisk and the app target, then retry."
                                : "No matching compiler command found. Build the target with EMIT_FRONTEND_COMMAND_LINES=YES and COMPILATION_CACHE_ENABLE_CACHING=NO.")
                    )
                )
            }
        }

        let requiredFailed = checks.contains {
            $0.state == .fail
        }

        return DoctorReport(
            ready: !requiredFailed,
            checks: checks,
            runtime: DoctorRuntime(
                connected: runtime.connected,
                platform: runtime.platform,
                arch: runtime.arch,
                temporaryPath: runtime.temporaryPath
            )
        )
    }

    private func record(
        error: ControlError,
        source: String?
    ) {
        backendStateLock.lock()
        lastErrorValue = error
        lastSourceValue = source
        backendStateLock.unlock()
    }

    private func clearLastError() {
        backendStateLock.lock()
        lastErrorValue = nil
        lastSourceValue = nil
        backendStateLock.unlock()
    }

    private static func selectedXcodeDeveloperDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/xcode-select"
        )
        process.arguments = ["-p"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let value = String(
                    data: data,
                    encoding: .utf8
                  )?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ),
                  !value.isEmpty,
                  FileManager.default.fileExists(atPath: value)
            else {
                return nil
            }

            return value
        } catch {
            return nil
        }
    }

    private func normalize(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
                .standardizedFileURL
                .path
        }

        let base = projectRoot
            ?? FileManager.default.currentDirectoryPath

        return URL(fileURLWithPath: base)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }
}

