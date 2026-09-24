import XCTest
@testable import AgentInjectionCore

final class ControlRouterTests: XCTestCase {
    func testStatusReportsScaffoldBackend() throws {
        let backend = ScaffoldInjectionBackend(projectRoot: "/tmp/project")
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(action: .status)
        let response = try route(request, through: router)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.status?.backend.name, "scaffold")
        XCTAssertEqual(response.status?.backend.ready, false)
        XCTAssertEqual(response.status?.socketPath, "/tmp/test-agentInjectionIII.sock")
    }

    func testInjectReturnsExplicitBackendNotReadyError() throws {
        let backend = ScaffoldInjectionBackend(projectRoot: "/repo")
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(
            action: .inject,
            files: ["Sources/Foo.swift", "Sources/Bar.m"]
        )
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "BACKEND_NOT_READY")
        XCTAssertEqual(response.injections?.count, 2)
        XCTAssertEqual(response.injections?.first?.file, "/repo/Sources/Foo.swift")
        XCTAssertEqual(response.injections?.first?.compiled, false)
        XCTAssertEqual(response.injections?.first?.injected, false)
    }

    func testInjectRequiresFiles() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(action: .inject, files: [])
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "MISSING_FILES")
    }

    private func route(
        _ request: ControlRequest,
        through router: ControlRouter
    ) throws -> ControlResponse {
        let encoded = try ControlCodec.encoder.encode(request)
        let responseData = router.handle(encoded)
        return try ControlCodec.decoder.decode(
            ControlResponse.self,
            from: responseData
        )
    }
}
