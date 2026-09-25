import XCTest
@testable import AgentInjectionCore

final class BuildLogCompilerTests: XCTestCase {
    func testSwiftRewriteKeepsOnlyRequestedPrimaryFile() {
        let compiler = BuildLogCompiler()
        let source = "/repo/Sources/Foo.swift"
        let other = "/repo/Sources/Bar.swift"
        let output = "/tmp/old.o"

        let original = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            "-frontend",
            "-emit-object",
            "-primary-file", source,
            "-primary-file", other,
            "-target", "arm64-apple-ios18.0-simulator",
            "-sdk", "/Applications/Xcode.app/SDK",
            "-o", output
        ].joined(separator: " ")

        let rewritten = compiler.makeSingleFileCommand(
            original: original,
            source: source,
            object: "/tmp/new.o"
        )

        XCTAssertTrue(rewritten.contains(" -primary-file \(source)"))
        XCTAssertFalse(rewritten.contains(other))
        XCTAssertFalse(rewritten.contains(output))
        XCTAssertTrue(rewritten.contains(" -o '/tmp/new.o'"))
        XCTAssertTrue(rewritten.contains(" -DDEBUG -DINJECTING"))
        XCTAssertFalse(rewritten.contains("-emit-object"))
    }

    func testSwiftRewriteHandlesQuotedSourceWithSpaces() {
        let compiler = BuildLogCompiler()
        let source = "/repo/My App/Foo.swift"
        let other = "/repo/My App/Bar.swift"

        let original = """
        /usr/bin/swift-frontend -frontend -emit-object         -primary-file "\(source)"         -primary-file "\(other)"         -target arm64-apple-ios18.0-simulator         -o "/tmp/old output.o"
        """

        let rewritten = compiler.makeSingleFileCommand(
            original: original,
            source: source,
            object: "/tmp/new output.o"
        )

        XCTAssertTrue(
            rewritten.contains("-primary-file \"\(source)\""),
            rewritten
        )
        XCTAssertFalse(rewritten.contains(other), rewritten)
        XCTAssertFalse(rewritten.contains("old output.o"), rewritten)
        XCTAssertTrue(
            rewritten.contains("-o '/tmp/new output.o'"),
            rewritten
        )
    }

    func testObjectiveCRewritePreservesCompileFlagsAndReplacesOutput() {
        let compiler = BuildLogCompiler()
        let source = "/repo/Sources/Foo.m"

        let original = """
        /usr/bin/clang -x objective-c -DCOCOAPODS=1         -I /repo/Pods/Headers/Public         -c \(source) -o /tmp/Foo.o
        """

        let rewritten = compiler.makeSingleFileCommand(
            original: original,
            source: source,
            object: "/tmp/agent-Foo.o"
        )

        XCTAssertTrue(rewritten.contains("-DCOCOAPODS=1"))
        XCTAssertTrue(rewritten.contains("-I /repo/Pods/Headers/Public"))
        XCTAssertTrue(rewritten.contains("-c \(source)"))
        XCTAssertFalse(rewritten.contains("/tmp/Foo.o"))
        XCTAssertTrue(rewritten.contains("-o '/tmp/agent-Foo.o'"))
        XCTAssertTrue(rewritten.contains("-Xclang -fno-validate-pch"))
    }

    func testCompilerDiagnosticsAreStructured() {
        let compiler = BuildLogCompiler()
        let output = """
        /repo/Sources/Foo.swift:42:17: error: cannot find 'missing' in scope
        /repo/Sources/Foo.swift:41:5: warning: immutable value was never used
        error: emit-module command failed with exit code 1
        """

        let diagnostics = compiler.parseCompilerDiagnostics(output)

        XCTAssertEqual(diagnostics.count, 3)

        XCTAssertEqual(
            diagnostics[0].file,
            "/repo/Sources/Foo.swift"
        )
        XCTAssertEqual(diagnostics[0].line, 42)
        XCTAssertEqual(diagnostics[0].column, 17)
        XCTAssertEqual(diagnostics[0].severity, "error")
        XCTAssertEqual(
            diagnostics[0].message,
            "cannot find 'missing' in scope"
        )

        XCTAssertEqual(diagnostics[1].severity, "warning")
        XCTAssertEqual(diagnostics[2].severity, "error")
        XCTAssertNil(diagnostics[2].file)
    }

    func testFindsBuildLogsInDirectDerivedDataPath() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentInjectionIII-derived-direct-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let logs = root
            .appendingPathComponent("Logs/Build")
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        let log = logs
            .appendingPathComponent(
                "direct.xcactivitylog"
            )
        try Data([0x1f, 0x8b]).write(
            to: log
        )

        let compiler = BuildLogCompiler(
            derivedDataRoot: root.path,
            cacheRoot: root
                .appendingPathComponent("cache")
                .path
        )
        let diagnostics = compiler.diagnostics()

        XCTAssertEqual(
            diagnostics.buildLogCount,
            1
        )
        XCTAssertTrue(
            diagnostics.newestBuildLog?
                .hasSuffix(
                    "/Logs/Build/direct.xcactivitylog"
                ) == true
        )
    }

    func testFindsBuildLogsInDerivedDataContainer() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentInjectionIII-derived-container-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let logs = root
            .appendingPathComponent(
                "Demo-ABC123/Logs/Build"
            )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        let log = logs
            .appendingPathComponent(
                "nested.xcactivitylog"
            )
        try Data([0x1f, 0x8b]).write(
            to: log
        )

        let compiler = BuildLogCompiler(
            derivedDataRoot: root.path,
            cacheRoot: root
                .appendingPathComponent("cache")
                .path
        )
        let diagnostics = compiler.diagnostics()

        XCTAssertEqual(
            diagnostics.buildLogCount,
            1
        )
        XCTAssertTrue(
            diagnostics.newestBuildLog?
                .hasSuffix(
                    "/Demo-ABC123/Logs/Build/nested.xcactivitylog"
                ) == true
        )
    }

    func testDetectsBazelWorkspaceWithoutXcodeBuildLogs() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentInjectionIII-bazel-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        let package = root
            .appendingPathComponent("App")
        try FileManager.default
            .createDirectory(
                at: package,
                withIntermediateDirectories: true
            )

        try "module(name = \"demo\")\n".write(
            to: root.appendingPathComponent(
                "MODULE.bazel"
            ),
            atomically: true,
            encoding: .utf8
        )
        try "swift_library(name = \"app\")\n".write(
            to: package.appendingPathComponent(
                "BUILD"
            ),
            atomically: true,
            encoding: .utf8
        )

        let source = package
            .appendingPathComponent("Feature.swift")
        try "struct Feature {}\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )

        let compiler = BuildLogCompiler(
            projectRoot: root.path,
            cacheRoot: root
                .appendingPathComponent("cache")
                .path
        )

        XCTAssertEqual(
            compiler.buildSystem(
                for: source.path
            ),
            "bazel"
        )
    }


    func testDiagnosticsSelectsRuntimeArchitectureAcrossMultipleCommands() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentInjectionIII-context-arch-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let source = root.appendingPathComponent("Feature.swift")
        try "struct Feature {}\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )

        let log = root.appendingPathComponent(
            "frontend-commands.log"
        )
        let sdk =
            "/Applications/Xcode.app/Contents/Developer/Platforms/" +
            "iPhoneSimulator.platform/Developer/SDKs/" +
            "iPhoneSimulator26.0.sdk"

        let commands = [
            "x86_64-apple-ios18.0-simulator",
            "arm64-apple-ios18.0-simulator"
        ].map { triple in
            root.path + "\t" + [
                "/Applications/Xcode.app/Contents/Developer/" +
                    "Toolchains/XcodeDefault.xctoolchain/usr/bin/" +
                    "swift-frontend.save",
                "-frontend",
                "-c",
                "-primary-file", source.path,
                "-target", triple,
                "-sdk", sdk,
                "-module-name", "FeatureModule",
                "-D", "DEBUG"
            ].joined(separator: " ")
        }.joined(separator: "\n") + "\n"

        try commands.write(
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

        let diagnostics = compiler.diagnostics(
            source: source.path,
            platform: "iPhoneSimulator",
            arch: "arm64"
        )

        XCTAssertEqual(
            diagnostics.compileCommandFound,
            true
        )
        XCTAssertEqual(
            diagnostics.compileCommandCandidateCount,
            2
        )
        XCTAssertEqual(
            diagnostics.compileCommandArchitectures,
            ["arm64", "x86_64"]
        )
        XCTAssertEqual(
            diagnostics.compileCommandModules,
            ["FeatureModule"]
        )
        XCTAssertEqual(
            diagnostics.compileCommandAmbiguous,
            false
        )
    }

    func testDiagnosticsRejectsAmbiguousModulesForSameSwiftSource() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentInjectionIII-context-module-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let source = root.appendingPathComponent("Shared.swift")
        try "struct Shared {}\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )

        let log = root.appendingPathComponent(
            "frontend-commands.log"
        )
        let sdk =
            "/Applications/Xcode.app/Contents/Developer/Platforms/" +
            "iPhoneSimulator.platform/Developer/SDKs/" +
            "iPhoneSimulator26.0.sdk"

        let commands = [
            "FeatureA",
            "FeatureB"
        ].map { module in
            root.path + "\t" + [
                "/Applications/Xcode.app/Contents/Developer/" +
                    "Toolchains/XcodeDefault.xctoolchain/usr/bin/" +
                    "swift-frontend.save",
                "-frontend",
                "-c",
                "-primary-file", source.path,
                "-target", "arm64-apple-ios18.0-simulator",
                "-sdk", sdk,
                "-module-name", module,
                "-D", "DEBUG"
            ].joined(separator: " ")
        }.joined(separator: "\n") + "\n"

        try commands.write(
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

        let diagnostics = compiler.diagnostics(
            source: source.path,
            platform: "iPhoneSimulator",
            arch: "arm64"
        )

        XCTAssertEqual(
            diagnostics.compileCommandFound,
            false
        )
        XCTAssertEqual(
            diagnostics.compileCommandCandidateCount,
            2
        )
        XCTAssertEqual(
            diagnostics.compileCommandModules,
            ["FeatureA", "FeatureB"]
        )
        XCTAssertEqual(
            diagnostics.compileCommandArchitectures,
            ["arm64"]
        )
        XCTAssertEqual(
            diagnostics.compileCommandAmbiguous,
            true
        )
    }

}
