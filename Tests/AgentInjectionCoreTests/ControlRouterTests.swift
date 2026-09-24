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

    func testLoadDylibRoutesToBackend() throws {
        let backend = ScaffoldInjectionBackend(projectRoot: "/repo")
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(
            action: .loadDylib,
            path: "Build/test.dylib"
        )
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "RUNTIME_NOT_READY")
        XCTAssertEqual(
            response.injections?.first?.file,
            "/repo/Build/test.dylib"
        )
    }

    func testLoadDylibRequiresPath() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(action: .loadDylib)
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "MISSING_PATH")
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

    func testLoadDylibRequiresPath() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(action: .loadDylib)
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "MISSING_PATH")
    }

    func testSwiftCommandTransformerKeepsOnlyRequestedPrimary() throws {
        let source = "/repo/Sources/Foo.swift"
        let command = """
        /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend         -frontend -emit-object         -primary-file /repo/Sources/Foo.swift         -primary-file /repo/Sources/Bar.swift         -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk         -o /tmp/original.o
        """

        let transformed = HeadlessXcodeCompiler.CommandTransformer.prepare(
            command: command,
            source: source,
            objectPath: "/tmp/new.o"
        )

        XCTAssertNotNil(transformed)
        XCTAssertTrue(transformed?.contains("-primary-file /repo/Sources/Foo.swift") == true)
        XCTAssertFalse(transformed?.contains("-primary-file /repo/Sources/Bar.swift") == true)
        XCTAssertTrue(transformed?.contains("-o '/tmp/new.o'") == true)
    }

    func testSDKExtraction() throws {
        let command = """
        /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend         -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk
        """

        let sdk = HeadlessXcodeCompiler.CommandTransformer.extractSDKPath(
            from: command
        )

        XCTAssertEqual(
            sdk,
            "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        )
        XCTAssertEqual(
            sdk.flatMap {
                HeadlessXcodeCompiler.CommandTransformer.inferPlatform(
                    sdkPath: $0
                )
            },
            "iPhoneSimulator"
        )
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
