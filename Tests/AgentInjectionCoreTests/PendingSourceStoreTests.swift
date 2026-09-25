import XCTest
@testable import AgentInjectionCore

final class PendingSourceStoreTests:
    XCTestCase {
    func testPendingSourcesAreDeduplicatedAndRemovedOnSuccess() {
        let store = PendingSourceStore(
            projectRoot: "/tmp/project"
        )

        let added = store.add([
            "/tmp/project/Foo.swift",
            "/tmp/project/Bar.m",
            "/tmp/project/Foo.swift"
        ])

        XCTAssertEqual(
            added,
            [
                "/tmp/project/Foo.swift",
                "/tmp/project/Bar.m"
            ]
        )

        var snapshot = store.snapshot(
            watching: true
        )
        XCTAssertEqual(
            snapshot.projectRoot,
            "/tmp/project"
        )
        XCTAssertTrue(snapshot.watching)
        XCTAssertEqual(
            snapshot.files,
            [
                "/tmp/project/Foo.swift",
                "/tmp/project/Bar.m"
            ]
        )

        store.markInjected(
            "/tmp/project/Foo.swift"
        )
        snapshot = store.snapshot(
            watching: true
        )

        XCTAssertEqual(
            snapshot.files,
            ["/tmp/project/Bar.m"]
        )
    }
}
