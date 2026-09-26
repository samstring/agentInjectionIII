import XCTest
@testable import AgentInjectionCore

final class MultiProjectInjectionBackendTests:
    XCTestCase {

    func testProjectIdentityIsStableAndPathAware() {
        let first =
            ProjectSessionIdentity.id(
                forRoot: "/tmp/AppA/."
            )
        let second =
            ProjectSessionIdentity.id(
                forRoot: "/tmp/AppA"
            )
        let other =
            ProjectSessionIdentity.id(
                forRoot: "/tmp/AppB"
            )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(
            ProjectSessionIdentity.contains(
                source:
                    "/tmp/AppA/Sources/View.swift",
                root: "/tmp/AppA"
            )
        )
        XCTAssertFalse(
            ProjectSessionIdentity.contains(
                source:
                    "/tmp/AppB/Sources/View.swift",
                root: "/tmp/AppA"
            )
        )
    }

    func testRuntimeProjectRootMatching() {
        XCTAssertTrue(
            ProjectSessionIdentity.runtimeMatches(
                projectRoot: "/tmp/AppA",
                runtimeProjectRoot: "/tmp/AppA"
            )
        )
        XCTAssertTrue(
            ProjectSessionIdentity.runtimeMatches(
                projectRoot: "/tmp/AppA",
                runtimeProjectRoot:
                    "/tmp/AppA/Subproject"
            )
        )
        XCTAssertFalse(
            ProjectSessionIdentity.runtimeMatches(
                projectRoot: "/tmp/AppA",
                runtimeProjectRoot: "/tmp/AppB"
            )
        )
    }

    func testProjectSessionsCanBeAddedAndRemoved()
        throws {
        let rootA =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-AppA-" +
                    UUID().uuidString
                )
        let rootB =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-AppB-" +
                    UUID().uuidString
                )

        try FileManager.default.createDirectory(
            at: rootA,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootB,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: rootA
            )
            try? FileManager.default.removeItem(
                at: rootB
            )
        }

        let runtime =
            InjectionNextRuntimeServer(
                port: 19887
            )
        let trace =
            AgentTraceServer(
                port: 19888
            )
        let backend =
            MultiProjectInjectionBackend(
                runtimeServer: runtime,
                traceServer: trace,
                projectRoots: [rootA.path]
            )

        XCTAssertEqual(
            backend.projects().projects.count,
            1
        )

        switch backend.addProject(
            root: rootB.path
        ) {
        case .success(let project):
            XCTAssertEqual(
                project.root,
                rootB.standardizedFileURL.path
            )
        case .failure(let error):
            XCTFail(
                "add project failed: \(error)"
            )
        }

        let projects = backend.projects()
        XCTAssertEqual(
            projects.projects.count,
            2
        )

        let idB =
            ProjectSessionIdentity.id(
                forRoot: rootB.path
            )
        switch backend.removeProject(id: idB) {
        case .success(let result):
            XCTAssertEqual(
                result.projects.count,
                1
            )
        case .failure(let error):
            XCTFail(
                "remove project failed: \(error)"
            )
        }
    }

    func testControlRequestProjectIDIsOptionalAndRoundTrips()
        throws {
        let legacy = ControlRequest(
            action: .pendingChanges
        )
        let legacyData =
            try ControlCodec.encoder.encode(
                legacy
            )
        let legacyDecoded =
            try ControlCodec.decoder.decode(
                ControlRequest.self,
                from: legacyData
            )
        XCTAssertNil(
            legacyDecoded.projectID
        )

        let request = ControlRequest(
            action: .pendingChanges,
            projectID: "project-123"
        )
        let data =
            try ControlCodec.encoder.encode(
                request
            )
        let decoded =
            try ControlCodec.decoder.decode(
                ControlRequest.self,
                from: data
            )

        XCTAssertEqual(
            decoded.projectID,
            "project-123"
        )
    }

    func testControlRouterExposesProjects()
        throws {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-Router-" +
                    UUID().uuidString
                )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let backend =
            MultiProjectInjectionBackend(
                runtimeServer:
                    InjectionNextRuntimeServer(
                        port: 19987
                    ),
                traceServer:
                    AgentTraceServer(
                        port: 19988
                    ),
                projectRoots: [root.path]
            )
        let router = ControlRouter(
            socketPath:
                "/tmp/agentInjectionIII-test.sock",
            backend: backend
        )

        let request = ControlRequest(
            action: .projects
        )
        let encoded =
            try ControlCodec.encoder.encode(
                request
            )
        let response =
            try ControlCodec.decoder.decode(
                ControlResponse.self,
                from: router.handle(encoded)
            )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(
            response.projects?.projects.count,
            1
        )
        XCTAssertEqual(
            response.projects?.projects.first?.root,
            root.standardizedFileURL.path
        )
    }
}
