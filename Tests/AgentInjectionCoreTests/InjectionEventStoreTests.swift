import XCTest
@testable import AgentInjectionCore

final class InjectionEventStoreTests: XCTestCase {
    func testSnapshotDoesNotConsumeEvents() {
        let store = InjectionEventStore()

        store.append(
            phase: "compiling",
            source: "/repo/Foo.swift"
        )
        store.append(
            phase: "failed",
            source: "/repo/Foo.swift",
            message: "compile failed"
        )

        XCTAssertEqual(
            store.snapshot().events.count,
            2
        )
        XCTAssertEqual(
            store.snapshot().events.count,
            2
        )
        XCTAssertEqual(
            store.drain().events.count,
            2
        )
        XCTAssertEqual(
            store.snapshot().events.count,
            2
        )
    }

    func testSnapshotLimitReturnsNewestEvents() {
        let store = InjectionEventStore()

        for index in 0..<5 {
            store.append(
                phase: "phase-\(index)"
            )
        }

        let snapshot =
            store.snapshot(limit: 2)

        XCTAssertEqual(
            snapshot.events.map(\.phase),
            ["phase-3", "phase-4"]
        )
    }
}
