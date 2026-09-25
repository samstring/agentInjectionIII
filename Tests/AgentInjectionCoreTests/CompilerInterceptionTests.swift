import XCTest
@testable import AgentInjectionCore

final class CompilerInterceptionTests: XCTestCase {
    func testPatchAndUnpatchFakeXcodeToolchain() throws {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(UUID().uuidString)

        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let xcode = root.appendingPathComponent(
            "Xcode.app"
        )
        let bin = xcode.appendingPathComponent(
            "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        )
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        let frontend = bin.appendingPathComponent(
            "swift-frontend"
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: frontend,
            atomically: true,
            encoding: .utf8
        )

        for tool in [
            "swift",
            "swiftc",
            "swift-symbolgraph-extract",
            "swift-api-digester",
            "swift-cache-tool"
        ] {
            let url = bin.appendingPathComponent(tool)
            try "placeholder".write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        }

        let compiler = BuildLogCompiler(
            cacheRoot: root
                .appendingPathComponent("cache")
                .path,
            xcodePath: xcode.path
        )
        let manager = CompilerInterceptionManager(
            compiler: compiler
        )

        switch manager.setEnabled(true) {
        case .failure(let error):
            XCTFail(error.message)
        case .success(let state):
            XCTAssertTrue(state.intercepted)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: frontend.path + ".save"
            )
        )

        let feeder = try String(
            contentsOf: frontend,
            encoding: .utf8
        )
        XCTAssertTrue(
            feeder.contains("frontend-commands.log")
        )
        XCTAssertTrue(
            feeder.contains("exec -a \"$tool\" \"$real\" \"$@\"")
        )

        let swiftc = bin.appendingPathComponent(
            "swiftc"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: swiftc.path
            ),
            "swift-frontend"
        )

        switch manager.setEnabled(false) {
        case .failure(let error):
            XCTFail(error.message)
        case .success(let state):
            XCTAssertFalse(state.intercepted)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: frontend.path + ".save"
            )
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: swiftc.path
            ),
            "swift-frontend"
        )
    }

    func testInterceptedCommandIsImportedIntoCompilerCache() throws {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(UUID().uuidString)

        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let source = root.appendingPathComponent(
            "Feature.swift"
        )
        try "struct Feature {}\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )

        let log = root.appendingPathComponent(
            "frontend-commands.log"
        )
        let line = [
            root.path,
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend.save",
            "-frontend",
            "-c",
            "-primary-file",
            source.path,
            "-sdk",
            "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.0.sdk"
        ]

        try (
            line[0] + "\t" +
            line.dropFirst().joined(separator: " ") +
            "\n"
        ).write(
            to: log,
            atomically: true,
            encoding: .utf8
        )

        let compiler = BuildLogCompiler(
            projectRoot: root.path,
            cacheRoot: root
                .appendingPathComponent("cache")
                .path,
            interceptionLogPath: log.path
        )

        compiler.ingestInterceptedCommands()

        XCTAssertTrue(
            compiler.knownSwiftSources()
                .contains(source.path)
        )

        let diagnostics = compiler.diagnostics(
            source: source.path,
            platform: "iPhoneSimulator"
        )
        XCTAssertEqual(
            diagnostics.compileCommandFound,
            true
        )
        XCTAssertEqual(
            compiler.interceptedCommandCount(),
            1
        )
    }
}
