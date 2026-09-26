import Foundation

public final class AgentLogStore {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maximumEntries: Int

    public init(maximumEntries: Int = 5_000) {
        self.maximumEntries = max(100, maximumEntries)
    }

    public func append(
        _ message: String,
        level: String = "info",
        timestamp: Double = Date.timeIntervalSinceReferenceDate
    ) {
        lock.lock()
        entries.append(
            LogEntry(
                timestamp: timestamp,
                level: level,
                message: message
            )
        )

        if entries.count > maximumEntries {
            entries.removeFirst(
                entries.count - maximumEntries
            )
        }
        lock.unlock()

        UnifiedDiagnosticLog.shared?.append(
            category: "runtime",
            level: level,
            message: message
        )
    }

    public func get(
        since: Double? = nil,
        limit: Int? = nil
    ) -> LogsResult {
        lock.lock()
        defer { lock.unlock() }

        var selected = entries
        if let since {
            selected = selected.filter {
                $0.timestamp > since
            }
        }

        if let limit {
            let bounded = max(0, min(limit, 1_000))
            if selected.count > bounded {
                selected = Array(selected.suffix(bounded))
            }
        }

        return LogsResult(entries: selected)
    }

    @discardableResult
    public func clear() -> LogsResult {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
        return LogsResult(entries: [])
    }
}
