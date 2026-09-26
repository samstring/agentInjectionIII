import Foundation
import Darwin

/// Single on-disk diagnostic stream shared by daemon lifecycle, runtime,
/// injection lifecycle and control-plane diagnostics.
///
/// The file is intentionally current-day only: when a new daemon starts and
/// the existing file was last modified on a previous calendar day, it is
/// truncated before new entries are appended.
public final class UnifiedDiagnosticLog: @unchecked Sendable {
    public static let defaultLogURL =
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Logs/AgentInjectionIII/diagnostics.log"
            )

    private static let sharedLock = NSLock()
    private static var sharedValue:
        UnifiedDiagnosticLog?

    public static var shared:
        UnifiedDiagnosticLog? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedValue
    }

    @discardableResult
    public static func configureDefault()
        throws -> UnifiedDiagnosticLog {
        let log = try UnifiedDiagnosticLog(
            url: defaultLogURL
        )

        sharedLock.lock()
        sharedValue = log
        sharedLock.unlock()

        return log
    }

    public let url: URL

    private let lock = NSLock()
    private let handle: FileHandle
    private let formatter =
        ISO8601DateFormatter()

    public init(
        url: URL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        self.url = url

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var truncate = false
        if fileManager.fileExists(
            atPath: url.path
        ) {
            let attributes =
                try? fileManager.attributesOfItem(
                    atPath: url.path
                )
            if let modified =
                attributes?[.modificationDate]
                    as? Date {
                truncate =
                    !calendar.isDate(
                        modified,
                        inSameDayAs: now
                    )
            }
        } else {
            fileManager.createFile(
                atPath: url.path,
                contents: nil
            )
        }

        let handle =
            try FileHandle(
                forWritingTo: url
            )
        if truncate {
            try handle.truncate(atOffset: 0)
        }
        try handle.seekToEnd()
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    public func append(
        category: String,
        level: String = "info",
        message: String,
        metadata: [String: String] = [:]
    ) {
        let timestamp =
            formatter.string(from: Date())
        let metadataText =
            metadata
                .sorted { $0.key < $1.key }
                .map {
                    "\($0.key)=\(Self.quote($0.value))"
                }
                .joined(separator: " ")

        let suffix =
            metadataText.isEmpty
            ? ""
            : " | \(metadataText)"
        let line =
            "\(timestamp) [\(category)] [\(level)] \(message)\(suffix)\n"

        lock.lock()
        defer { lock.unlock() }

        guard let data =
                line.data(using: .utf8) else {
            return
        }

        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // Logging must never take the daemon down.
        }
    }

    /// Redirect raw stdout/stderr emitted by dependencies into the same file.
    public func redirectStandardStreams() {
        lock.lock()
        let fd = handle.fileDescriptor
        _ = Darwin.dup2(
            fd,
            STDOUT_FILENO
        )
        _ = Darwin.dup2(
            fd,
            STDERR_FILENO
        )
        lock.unlock()
    }

    public static func tail(
        limit: Int = 200,
        url: URL = defaultLogURL
    ) throws -> [String] {
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            return []
        }

        let value =
            try String(
                contentsOf: url,
                encoding: .utf8
            )
        let lines =
            value.split(
                separator: "\n",
                omittingEmptySubsequences: true
            )
        let bounded =
            max(1, min(limit, 5_000))

        return lines.suffix(bounded)
            .map(String.init)
    }

    private static func quote(
        _ value: String
    ) -> String {
        if value.contains(where: {
            $0.isWhitespace ||
            $0 == "=" ||
            $0 == "\""
        }) {
            return "\"" +
                value.replacingOccurrences(
                    of: "\"",
                    with: "\\\""
                ) +
                "\""
        }
        return value
    }
}
