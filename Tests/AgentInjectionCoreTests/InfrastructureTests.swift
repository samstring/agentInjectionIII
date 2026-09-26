import XCTest
@testable import AgentInjectionCore

final class InfrastructureTests:
    XCTestCase {

    func testUnifiedDiagnosticLogTruncatesPreviousDay()
        throws {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-Log-" +
                    UUID().uuidString
                )
        let file =
            directory
                .appendingPathComponent(
                    "diagnostics.log"
                )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        try "yesterday\n".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let yesterday =
            Date().addingTimeInterval(
                -24 * 60 * 60
            )
        try FileManager.default
            .setAttributes(
                [
                    .modificationDate:
                        yesterday
                ],
                ofItemAtPath:
                    file.path
            )

        let log =
            try UnifiedDiagnosticLog(
                url: file
            )
        log.append(
            category: "test",
            message: "today"
        )

        let lines =
            try UnifiedDiagnosticLog
                .tail(
                    limit: 10,
                    url: file
                )

        XCTAssertEqual(
            lines.count,
            1
        )
        XCTAssertTrue(
            lines[0].contains(
                "today"
            )
        )
        XCTAssertFalse(
            lines[0].contains(
                "yesterday"
            )
        )
    }

    func testUnifiedDiagnosticLogKeepsSameDayEntries()
        throws {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-Log-" +
                    UUID().uuidString
                )
        let file =
            directory
                .appendingPathComponent(
                    "diagnostics.log"
                )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        try "earlier-today\n".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let log =
            try UnifiedDiagnosticLog(
                url: file
            )
        log.append(
            category: "test",
            message: "later-today"
        )

        let lines =
            try UnifiedDiagnosticLog
                .tail(
                    limit: 10,
                    url: file
                )

        XCTAssertEqual(
            lines.count,
            2
        )
        XCTAssertEqual(
            lines[0],
            "earlier-today"
        )
        XCTAssertTrue(
            lines[1].contains(
                "later-today"
            )
        )
    }

    func testDaemonSingletonLockRejectsSecondOwner()
        throws {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-Lock-" +
                    UUID().uuidString
                )
        let file =
            directory
                .appendingPathComponent(
                    "injectiond.lock"
                )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        let first =
            try DaemonSingletonLock(
                url: file
            )
        _ = first

        XCTAssertThrowsError(
            try DaemonSingletonLock(
                url: file
            )
        ) { error in
            guard case
                DaemonSingletonLockError
                    .alreadyRunning =
                    error else {
                return XCTFail(
                    "Unexpected error: \(error)"
                )
            }
        }
    }
}
