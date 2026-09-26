import Foundation
import Darwin

public enum DaemonSingletonLockError:
    Error,
    CustomStringConvertible {
    case alreadyRunning
    case openFailed(String)
    case lockFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "Another injectiond instance already owns the control-layer lock."
        case .openFailed(let message),
             .lockFailed(let message):
            return message
        }
    }
}

/// Process-wide guard for the single AgentInjectionIII control layer.
///
/// The lock is per macOS user and intentionally independent of the control
/// socket path so custom socket arguments cannot accidentally create a second
/// injectiond control layer.
public final class DaemonSingletonLock:
    @unchecked Sendable {

    public static let defaultLockURL =
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/AgentInjectionIII/injectiond.lock"
            )

    public let url: URL
    private let fd: Int32

    public init(
        url: URL = defaultLockURL
    ) throws {
        self.url = url

        try FileManager.default
            .createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

        let fd = Darwin.open(
            url.path,
            O_CREAT |
            O_RDWR |
            O_EXLOCK |
            O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fd >= 0 else {
            let code = errno
            if code == EWOULDBLOCK ||
               code == EAGAIN {
                throw DaemonSingletonLockError
                    .alreadyRunning
            }

            throw DaemonSingletonLockError
                .openFailed(
                    "Unable to open and lock daemon state at \(url.path): " +
                    String(
                        cString:
                            strerror(code)
                    )
                )
        }

        self.fd = fd

        let state =
            "pid=\(getpid())\n" +
            "started=\(ISO8601DateFormatter().string(from: Date()))\n"
        state.withCString {
            pointer in
            _ = Darwin.ftruncate(
                fd,
                0
            )
            _ = Darwin.write(
                fd,
                pointer,
                strlen(pointer)
            )
        }
        _ = Darwin.fsync(fd)
    }

    deinit {
        // Closing an O_EXLOCK descriptor releases the advisory lock,
        // including after process crash or SIGKILL.
        Darwin.close(fd)
    }
}
