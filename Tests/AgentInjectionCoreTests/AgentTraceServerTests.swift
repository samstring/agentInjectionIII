import XCTest
import Foundation
import Darwin
@testable import AgentInjectionCore

final class AgentTraceServerTests: XCTestCase {
    func testInjectedXCTestResultIsBuffered() throws {
        let port = UInt16(
            19_000 + Int(getpid()) % 1_000
        )
        let server = AgentTraceServer(
            port: port
        )
        try server.start()

        let fd = try Self.connect(
            port: port
        )
        defer { Darwin.close(fd) }

        let payload: [String: Any] = [
            "type": "test_result",
            "timestamp":
                Date.timeIntervalSinceReferenceDate,
            "testName":
                "InjectedTests.testExample",
            "passed": false,
            "failures": 1,
            "durationSeconds": 0.125,
            "messages": [
                "XCTAssertEqual failed"
            ]
        ]

        var data = try JSONSerialization.data(
            withJSONObject: payload
        )
        data.append(0x0A)
        try Self.writeAll(
            data,
            fd: fd
        )

        let deadline = Date()
            .addingTimeInterval(2)
        while Date() < deadline {
            if !server.injectedTestResults()
                .results.isEmpty {
                break
            }
            usleep(10_000)
        }

        let result =
            server.injectedTestResults()
        XCTAssertTrue(result.connected)
        XCTAssertEqual(
            result.results.count,
            1
        )

        let test = try XCTUnwrap(
            result.results.first
        )
        XCTAssertEqual(
            test.name,
            "InjectedTests.testExample"
        )
        XCTAssertFalse(test.passed)
        XCTAssertEqual(test.failures, 1)
        XCTAssertEqual(
            test.durationSeconds,
            0.125,
            accuracy: 0.001
        )
        XCTAssertEqual(
            test.messages,
            ["XCTAssertEqual failed"]
        )

        let cleared =
            server.clearInjectedTestResults()
        XCTAssertTrue(cleared.results.isEmpty)
    }

    private static func connect(
        port: UInt16
    ) throws -> Int32 {
        var lastError = "unknown"

        for _ in 0..<100 {
            let fd = Darwin.socket(
                AF_INET,
                SOCK_STREAM,
                0
            )
            guard fd >= 0 else {
                throw NSError(
                    domain: "AgentTraceServerTests",
                    code: 1
                )
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(
                MemoryLayout<sockaddr_in>.size
            )
            address.sin_family =
                sa_family_t(AF_INET)
            address.sin_port =
                port.bigEndian
            address.sin_addr = in_addr(
                s_addr:
                    inet_addr("127.0.0.1")
            )

            let result =
                withUnsafePointer(
                    to: &address
                ) {
                    $0.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        Darwin.connect(
                            fd,
                            $0,
                            socklen_t(
                                MemoryLayout<
                                    sockaddr_in
                                >.size
                            )
                        )
                    }
                }

            if result == 0 {
                return fd
            }

            lastError =
                String(
                    cString:
                        strerror(errno)
                )
            Darwin.close(fd)
            usleep(10_000)
        }

        throw NSError(
            domain: "AgentTraceServerTests",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "connect failed: \(lastError)"
            ]
        )
    }

    private static func writeAll(
        _ data: Data,
        fd: Int32
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base =
                    raw.baseAddress else {
                return
            }

            var offset = 0
            while offset < raw.count {
                let written =
                    Darwin.write(
                        fd,
                        base.advanced(
                            by: offset
                        ),
                        raw.count - offset
                    )

                guard written > 0 else {
                    throw NSError(
                        domain:
                            "AgentTraceServerTests",
                        code: 3
                    )
                }
                offset += written
            }
        }
    }
}
