import Foundation
import Darwin

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

        return data.withUnsafeBytes {
            $0.load(as: Int32.self)
        }
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
    public let connected: Bool
    public let platform: String?
    public let arch: String?
    public let temporaryPath: String?

    public init(
        connected: Bool,
        platform: String? = nil,
        arch: String? = nil,
        temporaryPath: String? = nil
    ) {
        self.connected = connected
        self.platform = platform
        self.arch = arch
        self.temporaryPath = temporaryPath
    }
}

private final class PendingRuntimeInjection {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded: Bool?
    var message: String?
}

private final class InjectionRuntimeClient {
    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private let operationLock = NSLock()

    private var platformValue: String?
    private var archValue: String?
    private var temporaryPathValue: String?
    private var connectedValue = true
    private var pendingInjection: PendingRuntimeInjection?

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    func validate() throws {
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
            string: Self.xcodeApplicationPath()
        )
    }

    func processResponses(
        onDisconnect: @escaping () -> Void
    ) {
        defer {
            stateLock.lock()
            connectedValue = false
            let pending = pendingInjection
            pendingInjection = nil
            stateLock.unlock()

            if let pending {
                pending.succeeded = false
                pending.message = "Injection runtime disconnected."
                pending.semaphore.signal()
            }

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
                        temporaryPathValue = path
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            .isEmpty ? "/" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == path
                                ? path
                                : String(path.dropLast())
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

                case .projectRoot,
                     .detail,
                     .bazelTarget,
                     .executable,
                     .touchEvent,
                     .replayComplete:
                    _ = try InjectionNextWire.readString(from: fd)

                case .screenshotData:
                    _ = try InjectionNextWire.readString(from: fd)
                    _ = try InjectionNextWire.readData(from: fd)

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
            connected: connectedValue,
            platform: platformValue,
            arch: archValue,
            temporaryPath: temporaryPathValue
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

        guard let tmpPath = status().temporaryPath else {
            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Runtime is connected but has not reported its temporary path yet."
            )
        }

        let destinationURL = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent(
                "agent_injection_\(UUID().uuidString).dylib"
            )

        do {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destinationURL
            )
        } catch {
            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Unable to copy dylib into runtime temp directory: \(error)"
            )
        }

        defer {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let pending = PendingRuntimeInjection()

        stateLock.lock()
        pendingInjection = pending
        stateLock.unlock()

        do {
            try send(
                command: .load,
                string: destinationURL.path
            )
        } catch {
            stateLock.lock()
            if pendingInjection === pending {
                pendingInjection = nil
            }
            stateLock.unlock()

            return InjectionResult(
                file: sourcePath,
                compiled: true,
                injected: false,
                message: "Unable to send load command: \(error)"
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

    private let queue = DispatchQueue(
        label: "agentInjectionIII.runtime-server",
        qos: .userInitiated
    )
    private let stateLock = NSLock()

    private var listenerFD: Int32 = -1
    private var currentClient: InjectionRuntimeClient?

    public init(port: UInt16 = 8887) {
        self.port = port
    }

    deinit {
        if listenerFD >= 0 {
            Darwin.close(listenerFD)
        }
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
                code: "RUNTIME_BIND_FAILED",
                message: "Unable to bind 127.0.0.1:\(port): \(String(cString: strerror(errno)))"
            )
        }

        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw ControlError(
                code: "RUNTIME_LISTEN_FAILED",
                message: "listen() failed: \(String(cString: strerror(errno)))"
            )
        }

        listenerFD = fd

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func status() -> InjectionRuntimeStatus {
        stateLock.lock()
        let client = currentClient
        stateLock.unlock()

        return client?.status()
            ?? InjectionRuntimeStatus(connected: false)
    }

    public func loadDylib(path: String) -> InjectionResult {
        stateLock.lock()
        let client = currentClient
        stateLock.unlock()

        guard let client else {
            return InjectionResult(
                file: path,
                compiled: true,
                injected: false,
                message: "No InjectionNext runtime is connected."
            )
        }

        return client.loadDylib(sourcePath: path)
    }

    private func acceptLoop() {
        while listenerFD >= 0 {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                continue
            }

            let client = InjectionRuntimeClient(fd: fd)

            do {
                try client.validate()
            } catch {
                continue
            }

            stateLock.lock()
            currentClient = client
            stateLock.unlock()

            queue.async { [weak self, weak client] in
                guard let self, let client else { return }
                client.processResponses {
                    self.stateLock.lock()
                    if self.currentClient === client {
                        self.currentClient = nil
                    }
                    self.stateLock.unlock()
                }
            }
        }
    }
}

public final class InjectionNextRuntimeBackend: InjectionBackend {
    public let name = "injectionnext-runtime"

    private let runtimeServer: InjectionNextRuntimeServer
    private let projectRoot: String?

    public init(
        runtimeServer: InjectionNextRuntimeServer,
        projectRoot: String? = nil
    ) {
        self.runtimeServer = runtimeServer
        self.projectRoot = projectRoot
    }

    public func status() -> BackendStatus {
        let runtime = runtimeServer.status()

        return BackendStatus(
            name: name,
            ready: false,
            appConnected: runtime.connected,
            capabilities: [
                "status",
                "load-dylib",
                "source-inject-pending"
            ],
            detail: runtime.connected
                ? "InjectionNext runtime connected; source recompilation backend is the next phase."
                : "Listening for InjectionNext runtime on 127.0.0.1:\(runtimeServer.port)."
        )
    }

    public func inject(files: [String]) -> BackendInjectionResponse {
        let results = files.map { file in
            InjectionResult(
                file: normalize(path: file),
                compiled: false,
                injected: false,
                message: "Source compiler backend is not connected yet."
            )
        }

        return BackendInjectionResponse(
            results: results,
            error: ControlError(
                code: "COMPILER_BACKEND_NOT_READY",
                message: "Runtime transport is available, but source recompilation is not wired yet."
            )
        )
    }

    public func loadDylib(path: String) -> BackendInjectionResponse {
        let normalized = normalize(path: path)
        let result = runtimeServer.loadDylib(path: normalized)

        return BackendInjectionResponse(
            results: [result],
            error: result.injected
                ? nil
                : ControlError(
                    code: "DYLIB_INJECTION_FAILED",
                    message: result.message ?? "Runtime failed to inject dylib."
                )
        )
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
