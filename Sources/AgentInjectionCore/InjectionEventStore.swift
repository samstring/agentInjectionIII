import Foundation

public final class InjectionEventStore {
    private let lock = NSLock()
    private var events: [InjectionEvent] = []
    private var nextSequence: Int64 = 1
    private let maximumEvents: Int

    public init(maximumEvents: Int = 5_000) {
        self.maximumEvents = max(100, maximumEvents)
    }

    public func append(
        phase: String,
        source: String? = nil,
        target: String? = nil,
        message: String? = nil,
        compileMilliseconds: Double? = nil,
        linkMilliseconds: Double? = nil
    ) {
        lock.lock()
        events.append(
            InjectionEvent(
                sequence: nextSequence,
                timestamp: Date.timeIntervalSinceReferenceDate,
                phase: phase,
                source: source,
                target: target,
                message: message,
                compileMilliseconds: compileMilliseconds,
                linkMilliseconds: linkMilliseconds
            )
        )
        nextSequence += 1

        if events.count > maximumEvents {
            events.removeFirst(
                events.count - maximumEvents
            )
        }
        lock.unlock()
    }

    public func snapshot(
        limit: Int? = nil
    ) -> InjectionEventsResult {
        lock.lock()
        defer { lock.unlock() }

        var selected = events
        if let limit {
            let bounded = max(0, min(limit, 1_000))
            if selected.count > bounded {
                selected = Array(selected.suffix(bounded))
            }
        }

        return InjectionEventsResult(
            events: selected
        )
    }

    public func drain(
        limit: Int? = nil
    ) -> InjectionEventsResult {
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

        return InjectionEventsResult(
            events: drained
        )
    }

    public func clear() -> InjectionEventsResult {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        lock.unlock()
        return InjectionEventsResult(events: [])
    }
}
