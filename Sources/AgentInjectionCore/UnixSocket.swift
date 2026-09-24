import Foundation
import Darwin

public enum UnixSocketError: Error, CustomStringConvertible {
    case createFailed(String)
    case pathTooLong(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case emptyResponse

    public var description: String {
        switch self {
        case .createFailed(let message),
             .pathTooLong(let message),
             .bindFailed(let message),
             .listenFailed(let message),
             .connectFailed(let message),
             .readFailed(let message),
             .writeFailed(let message):
            return message
        case .emptyResponse:
            return "Socket closed without a response."
        }
    }
}

private enum UnixSocketIO {
    static let maximumMessageBytes = 1024 * 1024

    static func makeSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.createFailed(
                "socket(AF_UNIX) failed: \(String(cString: strerror(errno)))"
            )
        }

        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        return fd
    }

    static func withAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw UnixSocketError.pathTooLong(
                "Unix socket path is too long (max \(capacity - 1) bytes): \(path)"
            )
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            path.withCString { source in
                guard let base = buffer.baseAddress else { return }
                strncpy(
                    base.assumingMemoryBound(to: CChar.self),
                    source,
                    capacity - 1
                )
            }
        }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { sockaddrPointer in
                try body(
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
    }

    static func readMessage(from fd: Int32) throws -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while received.count <= maximumMessageBytes {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }

            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.readFailed(
                    "read() failed: \(String(cString: strerror(errno)))"
                )
            }

            if count == 0 {
                break
            }

            received.append(contentsOf: buffer[0..<count])

            if let newline = received.firstIndex(of: 0x0A) {
                return Data(received[..<newline])
            }
        }

        guard received.count <= maximumMessageBytes else {
            throw UnixSocketError.readFailed(
                "Request exceeds \(maximumMessageBytes) bytes."
            )
        }

        return received
    }

    static func writeMessage(_ data: Data, to fd: Int32) throws {
        var framed = data
        framed.append(0x0A)

        try framed.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }

            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )

                if written < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.writeFailed(
                        "write() failed: \(String(cString: strerror(errno)))"
                    )
                }

                offset += written
            }
        }
    }
}

public final class UnixSocketClient {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try UnixSocketIO.makeSocket()
        defer { Darwin.close(fd) }

        try UnixSocketIO.withAddress(path: socketPath) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw UnixSocketError.connectFailed(
                    "Unable to connect to \(socketPath): " +
                    String(cString: strerror(errno))
                )
            }
        }

        let encoded = try ControlCodec.encoder.encode(request)
        try UnixSocketIO.writeMessage(encoded, to: fd)

        let responseData = try UnixSocketIO.readMessage(from: fd)
        guard !responseData.isEmpty else {
            throw UnixSocketError.emptyResponse
        }

        return try ControlCodec.decoder.decode(
            ControlResponse.self,
            from: responseData
        )
    }
}

public final class UnixSocketServer {
    public typealias Handler = (Data) -> Data

    public let socketPath: String
    private let handler: Handler
    private var serverFD: Int32 = -1

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        if serverFD >= 0 {
            Darwin.close(serverFD)
        }
        unlink(socketPath)
    }

    public func run() throws {
        unlink(socketPath)

        serverFD = try UnixSocketIO.makeSocket()

        try UnixSocketIO.withAddress(path: socketPath) { address, length in
            guard Darwin.bind(serverFD, address, length) == 0 else {
                throw UnixSocketError.bindFailed(
                    "Unable to bind \(socketPath): " +
                    String(cString: strerror(errno))
                )
            }
        }

        chmod(socketPath, mode_t(S_IRUSR | S_IWUSR))

        guard Darwin.listen(serverFD, 16) == 0 else {
            throw UnixSocketError.listenFailed(
                "listen() failed: \(String(cString: strerror(errno)))"
            )
        }

        while true {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                continue
            }

            handle(clientFD)
        }
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        do {
            let request = try UnixSocketIO.readMessage(from: clientFD)
            guard !request.isEmpty else { return }

            let response = handler(request)
            try UnixSocketIO.writeMessage(response, to: clientFD)
        } catch {
            let response = ControlResponse.failure(
                code: "SOCKET_ERROR",
                message: String(describing: error)
            )

            if let encoded = try? ControlCodec.encoder.encode(response) {
                try? UnixSocketIO.writeMessage(encoded, to: clientFD)
            }
        }
    }
}
