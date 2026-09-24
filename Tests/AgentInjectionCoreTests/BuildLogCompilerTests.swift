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

}
