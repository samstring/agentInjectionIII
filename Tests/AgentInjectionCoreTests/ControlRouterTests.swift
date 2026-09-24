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

    func testTraceFailsCleanlyWithoutBridge() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        for action in [
            ControlAction.traceStart,
            ControlAction.traceRead,
            ControlAction.traceStop
        ] {
            let request = ControlRequest(action: action)
            let response = try route(request, through: router)

            XCTAssertFalse(response.ok)
            XCTAssertEqual(
                response.error?.code,
                "TRACE_BRIDGE_NOT_READY"
            )
            XCTAssertNil(response.trace)
        }
    }

    func testScreenshotFailsCleanlyWithoutRuntime() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(
            action: .screenshot,
            path: "/tmp/test.png"
        )
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "RUNTIME_NOT_READY")
        XCTAssertNil(response.screenshot)
    }

    func testDoctorReturnsStructuredFailureForScaffoldBackend() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let request = ControlRequest(action: .doctor)
        let response = try route(request, through: router)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "DOCTOR_NOT_READY")
        XCTAssertEqual(response.doctor?.ready, false)
        XCTAssertEqual(response.doctor?.checks.first?.name, "backend")
        XCTAssertEqual(response.doctor?.checks.first?.state, .fail)
    }

    func testXprobeAndEvalValidateAndFailCleanlyOnScaffold() throws {
        let backend = ScaffoldInjectionBackend()
        let router = ControlRouter(
            socketPath: "/tmp/test-agentInjectionIII.sock",
            backend: backend
        )

        let search = try route(
            ControlRequest(
                action: .xprobeSearch,
                filter: "UIViewController"
            ),
            through: router
        )
        XCTAssertFalse(search.ok)
        XCTAssertEqual(
            search.error?.code,
            "XPROBE_UNAVAILABLE"
        )

        let missingInspect = try route(
            ControlRequest(
                action: .xprobeInspect
            ),
            through: router
        )
        XCTAssertFalse(missingInspect.ok)
        XCTAssertEqual(
            missingInspect.error?.code,
            "MISSING_OBJECT_ID"
        )

        let inspect = try route(
            ControlRequest(
                action: .xprobeInspect,
                objectID: 7
            ),
            through: router
        )
        XCTAssertFalse(inspect.ok)
        XCTAssertEqual(
            inspect.error?.code,
            "XPROBE_UNAVAILABLE"
        )

        let missingEvalCode = try route(
            ControlRequest(
                action: .eval,
                objectID: 7
            ),
            through: router
        )
        XCTAssertFalse(missingEvalCode.ok)
        XCTAssertEqual(
            missingEvalCode.error?.code,
            "MISSING_CODE"
        )

        let eval = try route(
            ControlRequest(
                action: .eval,
                payload: "self.description",
                objectID: 7
            ),
            through: router
        )
        XCTAssertFalse(eval.ok)
        XCTAssertEqual(
            eval.error?.code,
            "XPROBE_UNAVAILABLE"
        )
    }

    func testBuildLogCompilerKeepsOnlyRequestedPrimary() throws {
        let compiler = BuildLogCompiler(projectRoot: "/repo")
        let source = "/repo/Sources/Foo.swift"
        let command = """
        /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend         -frontend -emit-object         -primary-file /repo/Sources/Foo.swift         -primary-file /repo/Sources/Bar.swift         -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk         -o /tmp/original.o
        """

        let transformed = compiler.makeSingleFileCommand(
            original: command,
            source: source,
            object: "/tmp/new.o"
        )

        XCTAssertTrue(
            transformed.contains("-primary-file /repo/Sources/Foo.swift")
        )
        XCTAssertFalse(
            transformed.contains("-primary-file /repo/Sources/Bar.swift")
        )
        XCTAssertTrue(
            transformed.contains("-o '/tmp/new.o'")
        )
        XCTAssertTrue(
            transformed.contains("-DINJECTING")
        )
    }

    func testCompilerDiagnosticsAreStructured() throws {
        let compiler = BuildLogCompiler(projectRoot: "/repo")
        let output = """
        /repo/Sources/Foo.swift:42:17: error: cannot find 'missing' in scope
        /repo/Sources/Foo.swift:43:9: warning: immutable value 'value' was never used
        note: while compiling requested source
        /repo/Sources/Foo.swift:42:17: error: cannot find 'missing' in scope
        """

        let diagnostics = compiler.parseCompilerDiagnostics(output)

        XCTAssertEqual(diagnostics.count, 3)

        XCTAssertEqual(diagnostics[0].file, "/repo/Sources/Foo.swift")
        XCTAssertEqual(diagnostics[0].line, 42)
        XCTAssertEqual(diagnostics[0].column, 17)
        XCTAssertEqual(diagnostics[0].severity, "error")
        XCTAssertEqual(
            diagnostics[0].message,
            "cannot find 'missing' in scope"
        )

        XCTAssertEqual(diagnostics[1].severity, "warning")
        XCTAssertEqual(diagnostics[2].severity, "note")
        XCTAssertNil(diagnostics[2].file)
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
