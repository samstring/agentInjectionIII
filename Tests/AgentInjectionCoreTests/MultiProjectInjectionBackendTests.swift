import XCTest
import Foundation
import Darwin
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


    func testAddingProjectDoesNotStealConnectedRuntime()
        throws {
        let base =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-StableRoute-" +
                    UUID().uuidString
                )
        let rootA =
            base.appendingPathComponent(
                "AppA"
            )
        let rootB =
            base.appendingPathComponent(
                "AppB"
            )

        try FileManager.default
            .createDirectory(
                at: rootA,
                withIntermediateDirectories: true
            )
        try FileManager.default
            .createDirectory(
                at: rootB,
                withIntermediateDirectories: true
            )
        defer {
            try? FileManager.default
                .removeItem(at: base)
        }

        let runtime =
            InjectionNextRuntimeServer(
                port: 19687
            )
        try runtime.start()

        let backend =
            MultiProjectInjectionBackend(
                runtimeServer: runtime,
                traceServer:
                    AgentTraceServer(
                        port: 19688
                    ),
                projectRoots: [rootA.path]
            )

        let keepAlive =
            DispatchSemaphore(value: 0)
        let connected =
            expectation(
                description:
                    "runtime connected"
            )

        DispatchQueue.global().async {
            do {
                let fd =
                    try Self.connect(
                        port: 19687
                    )
                defer {
                    Darwin.close(fd)
                }

                try Self.writeInt(
                    4001,
                    fd: fd
                )
                try Self.writeString(
                    NSHomeDirectory(),
                    fd: fd
                )

                _ = try Self.readInt(
                    fd: fd
                )
                _ = try Self.readString(
                    fd: fd
                )

                try Self.writeInt(
                    0,
                    fd: fd
                )
                try Self.writeString(
                    "iPhoneOS",
                    fd: fd
                )
                try Self.writeString(
                    "arm64",
                    fd: fd
                )

                try Self.writeInt(
                    5,
                    fd: fd
                )
                try Self.writeString(
                    base.path,
                    fd: fd
                )

                try Self.writeInt(
                    8,
                    fd: fd
                )
                try Self.writeString(
                    rootA
                        .appendingPathComponent(
                            "AppA"
                        )
                        .path,
                    fd: fd
                )

                connected.fulfill()
                _ = keepAlive.wait(
                    timeout:
                        .now() + 3
                )
            } catch {
                XCTFail(
                    "fake runtime failed: \(error)"
                )
            }
        }

        wait(
            for: [connected],
            timeout: 2
        )

        let deadline =
            Date()
                .addingTimeInterval(2)
        while Date() < deadline {
            if runtime.targets().first?
                .projectRoot != nil {
                break
            }
            usleep(10_000)
        }

        let before =
            backend.projects()
        let projectAID =
            ProjectSessionIdentity.id(
                forRoot: rootA.path
            )
        XCTAssertTrue(
            before.projects
                .first(
                    where: {
                        $0.id == projectAID
                    }
                )?
                .targetIDs
                .isEmpty == false
        )

        _ = backend.addProject(
            root: rootB.path
        )

        let after =
            backend.projects()
        XCTAssertTrue(
            after.projects
                .first(
                    where: {
                        $0.id == projectAID
                    }
                )?
                .targetIDs
                .isEmpty == false,
            "Adding another project must not reassign an existing runtime."
        )

        let projectBID =
            ProjectSessionIdentity.id(
                forRoot: rootB.path
            )
        XCTAssertTrue(
            after.projects
                .first(
                    where: {
                        $0.id == projectBID
                    }
                )?
                .targetIDs
                .isEmpty == true
        )

        keepAlive.signal()
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
            targets: ["runtime-a", "runtime-b"],
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
        XCTAssertEqual(
            decoded.targets,
            ["runtime-a", "runtime-b"]
        )
    }

    func testEmptyRuntimeSelectionDoesNotFallback()
        throws {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "AgentInjection-Selection-" +
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
                        port: 19787
                    ),
                traceServer:
                    AgentTraceServer(
                        port: 19788
                    ),
                projectRoots: [root.path]
            )

        let projectID =
            ProjectSessionIdentity.id(
                forRoot: root.path
            )
        let source =
            root.appendingPathComponent(
                "View.swift"
            ).path

        let response = backend.inject(
            files: [source],
            projectID: projectID,
            targets: []
        )

        XCTAssertEqual(
            response.error?.code,
            "NO_TARGETS_SELECTED"
        )
        XCTAssertFalse(
            response.results.first?.injected
                ?? true
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

    private static func connect(
        port: UInt16
    ) throws -> Int32 {
        let fd =
            Darwin.socket(
                AF_INET,
                SOCK_STREAM,
                0
            )
        guard fd >= 0 else {
            throw NSError(
                domain:
                    "MultiProjectTests",
                code: 1
            )
        }

        var address =
            sockaddr_in()
        address.sin_len =
            UInt8(
                MemoryLayout<
                    sockaddr_in
                >.size
            )
        address.sin_family =
            sa_family_t(AF_INET)
        address.sin_port =
            port.bigEndian
        address.sin_addr =
            in_addr(
                s_addr:
                    inet_addr(
                        "127.0.0.1"
                    )
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

        guard result == 0 else {
            Darwin.close(fd)
            throw NSError(
                domain:
                    "MultiProjectTests",
                code: 2
            )
        }

        return fd
    }

    private static func writeInt(
        _ value: Int32,
        fd: Int32
    ) throws {
        var value = value
        let data =
            Data(
                bytes: &value,
                count:
                    MemoryLayout<
                        Int32
                    >.size
            )
        try writeAll(
            data,
            fd: fd
        )
    }

    private static func readInt(
        fd: Int32
    ) throws -> Int32 {
        let data =
            try readExactly(
                MemoryLayout<
                    Int32
                >.size,
                fd: fd
            )
        var value: Int32 = 0
        data.withUnsafeBytes {
            raw in
            guard let base =
                    raw.baseAddress else {
                return
            }
            memcpy(
                &value,
                base,
                MemoryLayout<
                    Int32
                >.size
            )
        }
        return value
    }

    private static func writeString(
        _ value: String,
        fd: Int32
    ) throws {
        let data =
            Data(value.utf8)
        try writeInt(
            Int32(data.count),
            fd: fd
        )
        try writeAll(
            data,
            fd: fd
        )
    }

    private static func readString(
        fd: Int32
    ) throws -> String {
        let count =
            try readInt(fd: fd)
        let data =
            try readExactly(
                Int(count),
                fd: fd
            )
        guard let value =
                String(
                    data: data,
                    encoding: .utf8
                ) else {
            throw NSError(
                domain:
                    "MultiProjectTests",
                code: 3
            )
        }
        return value
    }

    private static func readExactly(
        _ count: Int,
        fd: Int32
    ) throws -> Data {
        var data =
            Data(count: count)
        var offset = 0

        try data
            .withUnsafeMutableBytes {
                raw in
                guard let base =
                        raw.baseAddress else {
                    return
                }

                while offset < count {
                    let readCount =
                        Darwin.read(
                            fd,
                            base.advanced(
                                by: offset
                            ),
                            count - offset
                        )

                    if readCount <= 0 {
                        throw NSError(
                            domain:
                                "MultiProjectTests",
                            code: 4
                        )
                    }
                    offset += readCount
                }
            }
        return data
    }

    private static func writeAll(
        _ data: Data,
        fd: Int32
    ) throws {
        try data.withUnsafeBytes {
            raw in
            guard let base =
                    raw.baseAddress else {
                return
            }
            var offset = 0

            while offset <
                    raw.count {
                let written =
                    Darwin.write(
                        fd,
                        base.advanced(
                            by: offset
                        ),
                        raw.count -
                            offset
                    )
                if written <= 0 {
                    throw NSError(
                        domain:
                            "MultiProjectTests",
                        code: 5
                    )
                }
                offset += written
            }
        }
    }


}
