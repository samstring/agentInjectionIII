import Foundation

/// Headless source recompiler inspired by InjectionLite's build-log strategy.
///
/// InjectionLite is MIT licensed:
/// Copyright (c) John Holdsworth.
/// This implementation intentionally keeps only the Xcode build-log path and
/// does not include its file watcher, Bazel integration, or runtime loader.
public final class BuildLogCompiler {
    public struct Artifact: Sendable {
        public let source: String
        public let object: String
        public let dylib: String
        public let compileMilliseconds: Double
        public let linkMilliseconds: Double
    }

    private struct CachedCommand: Codable {
        let command: String
        let logPath: String
    }

    private let projectRoot: String?
    private let fileManager = FileManager.default
    private let cacheLock = NSLock()
    private var memoryCache: [String: CachedCommand] = [:]

    private let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    private lazy var quotedArgumentRegex =
        #"(?:'[^']*'|"[^"]*"|\#(argumentRegex))"#
    private let optionsToRemove =
        #"(-(pch-output-dir|supplementary-output-file-map|emit-((reference-)?dependencies|const-values)|serialize-diagnostics|index-(store|unit-output))(-path)?|(-validate-clang-modules-once )?-clang-build-session-file|-Xcc -ivfsstatcache -Xcc)"#

    public init(projectRoot: String? = nil) {
        self.projectRoot = projectRoot
    }

    public func compileAndLink(
        source: String,
        platform: String,
        arch: String
    ) -> Result<Artifact, ControlError> {
        let source = standardized(source)

        guard fileManager.fileExists(atPath: source) else {
            return .failure(
                ControlError(
                    code: "SOURCE_NOT_FOUND",
                    message: "Source file does not exist: \(source)"
                )
            )
        }

        guard ["swift", "m", "mm", "cpp", "cc", "cxx"]
            .contains(URL(fileURLWithPath: source).pathExtension.lowercased())
        else {
            return .failure(
                ControlError(
                    code: "UNSUPPORTED_SOURCE",
                    message: "Unsupported injectable source: \(source)"
                )
            )
        }

        let cacheKey = source + "|" + platform
        let located: CachedCommand

        if let cached = cachedCommand(for: cacheKey) {
            located = cached
        } else {
            guard let command = locateCompilationCommand(
                source: source,
                platform: platform
            ) else {
                return .failure(
                    ControlError(
                        code: "COMPILE_COMMAND_NOT_FOUND",
                        message: """
                        Could not find the original Xcode compile command for \(source).                         Build the app once with this source in the target. For Swift on                         modern Xcode, set EMIT_FRONTEND_COMMAND_LINES=YES in Debug.
                        """
                    )
                )
            }

            located = command
            store(command, for: cacheKey)
        }

        let workDir = "/tmp/agentInjectionIII"
        do {
            try fileManager.createDirectory(
                atPath: workDir,
                withIntermediateDirectories: true
            )
        } catch {
            return .failure(
                ControlError(
                    code: "TEMP_DIRECTORY_FAILED",
                    message: "Unable to create \(workDir): \(error)"
                )
            )
        }

        let token = UUID().uuidString
        let object = "\(workDir)/\(token).o"
        let dylib = "\(workDir)/\(token).dylib"

        let compileCommand = makeSingleFileCommand(
            original: located.command,
            source: source,
            object: object
        )

        let compileStart = Date.timeIntervalSinceReferenceDate
        let compileResult = Shell.run(
            executable: "/bin/zsh",
            arguments: ["-lc", compileCommand],
            currentDirectory: projectRoot
        )
        let compileMs =
            (Date.timeIntervalSinceReferenceDate - compileStart) * 1000

        guard compileResult.status == 0,
              fileManager.fileExists(atPath: object) else {
            invalidate(cacheKey)
            return .failure(
                ControlError(
                    code: "COMPILE_FAILED",
                    message: """
                    Failed to recompile \(source).

                    Command:
                    \(compileCommand)

                    Output:
                    \(compileResult.combinedOutput)
                    """
                )
            )
        }

        let linkArguments = makeLinkArguments(
            object: object,
            dylib: dylib,
            compileCommand: located.command,
            platform: platform,
            arch: arch
        )

        let linkStart = Date.timeIntervalSinceReferenceDate
        let linkResult = Shell.run(
            executable: "/usr/bin/xcrun",
            arguments: linkArguments,
            currentDirectory: projectRoot
        )
        let linkMs =
            (Date.timeIntervalSinceReferenceDate - linkStart) * 1000

        guard linkResult.status == 0,
              fileManager.fileExists(atPath: dylib) else {
            try? fileManager.removeItem(atPath: object)
            return .failure(
                ControlError(
                    code: "LINK_FAILED",
                    message: """
                    Failed to link injection dylib for \(source).

                    xcrun \(linkArguments.joined(separator: " "))

                    Output:
                    \(linkResult.combinedOutput)
                    """
                )
            )
        }

        return .success(
            Artifact(
                source: source,
                object: object,
                dylib: dylib,
                compileMilliseconds: compileMs,
                linkMilliseconds: linkMs
            )
        )
    }

    public func remove(_ artifact: Artifact) {
        try? fileManager.removeItem(atPath: artifact.object)
        try? fileManager.removeItem(atPath: artifact.dylib)
    }

    private func locateCompilationCommand(
        source: String,
        platform: String
    ) -> CachedCommand? {
        let escapedSource = source
            .replacingOccurrences(of: " ", with: "\\ ")
        let basename = URL(fileURLWithPath: source).lastPathComponent
        let isSwift = source.hasSuffix(".swift")

        for logURL in buildLogsNewestFirst().prefix(80) {
            let result = Shell.run(
                executable: "/usr/bin/gunzip",
                arguments: ["-c", logURL.path]
            )

            guard result.status == 0 else { continue }

            let normalized = result.stdout
                .replacingOccurrences(of: "\r", with: "\n")

            for rawLine in normalized.split(
                separator: "\n",
                omittingEmptySubsequences: true
            ) {
                let line = String(rawLine)

                guard line.contains(basename) else { continue }
                guard platform.isEmpty ||
                        line.contains("SDKs/\(platform)") ||
                        line.contains("/\(platform).platform/")
                else { continue }

                let isCandidate: Bool
                if isSwift {
                    isCandidate =
                        line.contains(" -primary-file \(source) ") ||
                        line.contains(" -primary-file \(escapedSource) ")
                } else {
                    isCandidate =
                        line.contains(" -c \(source) ") ||
                        line.contains(" -c \(escapedSource) ")
                }

                guard isCandidate else { continue }

                if let command = extractCompilerCommand(
                    from: line,
                    swift: isSwift
                ) {
                    return CachedCommand(
                        command: command,
                        logPath: logURL.path
                    )
                }
            }
        }

        return nil
    }

    private func buildLogsNewestFirst() -> [URL] {
        let derivedData = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")

        guard let workspaces = try? fileManager.contentsOfDirectory(
            at: derivedData,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var logs: [(URL, Date)] = []

        for workspace in workspaces {
            let logsDirectory = workspace
                .appendingPathComponent("Logs/Build")

            guard let files = try? fileManager.contentsOfDirectory(
                at: logsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where file.pathExtension == "xcactivitylog" {
                let date = (
                    try? file.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                ) ?? .distantPast
                logs.append((file, date))
            }
        }

        return logs
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func extractCompilerCommand(
        from line: String,
        swift: Bool
    ) -> String? {
        let markers = swift
            ? ["/usr/bin/swift-frontend ", " swift-frontend "]
            : ["/usr/bin/clang ", " clang "]

        var earliest: String.Index?

        for marker in markers {
            if let range = line.range(of: marker) {
                let start: String.Index
                if marker.hasPrefix("/") {
                    start = findExecutableStart(
                        in: line,
                        endingAt: range.upperBound,
                        executable: swift ? "swift-frontend" : "clang"
                    ) ?? range.lowerBound
                } else {
                    start = range.lowerBound
                }

                if earliest == nil || start < earliest! {
                    earliest = start
                }
            }
        }

        guard let start = earliest else {
            return nil
        }

        var command = String(line[start...])
        command = command
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return command
    }

    private func findExecutableStart(
        in line: String,
        endingAt: String.Index,
        executable: String
    ) -> String.Index? {
        let prefix = line[..<endingAt]
        guard let range = prefix.range(
            of: "/",
            options: .backwards
        ) else {
            return nil
        }

        // The last slash is inside the executable path. Walk back to the
        // previous whitespace boundary to preserve the full absolute path.
        var index = range.lowerBound
        while index > line.startIndex {
            let previous = line.index(before: index)
            if line[previous].isWhitespace {
                break
            }
            index = previous
        }

        let candidate = String(line[index..<endingAt])
        return candidate.contains(executable) ? index : nil
    }

    private func makeSingleFileCommand(
        original: String,
        source: String,
        object: String
    ) -> String {
        if source.hasSuffix(".swift") {
            return makeSwiftCommand(
                original: original,
                source: source,
                object: object
            )
        }

        var command = original
        command = replacingRegex(
            " -o \(quotedArgumentRegex)",
            in: command,
            with: ""
        )

        command += " -o \(shellQuote(object))"
        command += " -DDEBUG -DINJECTING -Xclang -fno-validate-pch"
        return command
    }

    private func makeSwiftCommand(
        original: String,
        source: String,
        object: String
    ) -> String {
        var command = original
        let escapedSource = regexEscapeShellPath(source)

        command = replacingRegex(
            " -o \(quotedArgumentRegex)",
            in: command,
            with: " "
        )
        command = replacingRegex(
            " \(optionsToRemove) \(argumentRegex)",
            in: command,
            with: ""
        )

        command = command.replacingOccurrences(
            of: " -primary-file \(escapedSource)",
            with: " -agent-primary \(escapedSource)"
        )

        command = replacingRegex(
            " -primary-file \(argumentRegex)",
            in: command,
            with: " "
        )

        command = command.replacingOccurrences(
            of: "-agent-primary",
            with: "-primary-file"
        )
        command = command.replacingOccurrences(
            of: "-frontend-parseable-output ",
            with: ""
        )
        command = command.replacingOccurrences(
            of: " -emit-object",
            with: " -c"
        )

        command += " -o \(shellQuote(object)) -DDEBUG -DINJECTING"
        return command
    }

    private func makeLinkArguments(
        object: String,
        dylib: String,
        compileCommand: String,
        platform: String,
        arch: String
    ) -> [String] {
        let sdk: String
        switch platform {
        case "iPhoneOS":
            sdk = "iphoneos"
        case "AppleTVSimulator":
            sdk = "appletvsimulator"
        case "AppleTVOS":
            sdk = "appletvos"
        case "XRSimulator":
            sdk = "xrsimulator"
        case "XROS":
            sdk = "xros"
        case "MacOSX":
            sdk = "macosx"
        default:
            sdk = "iphonesimulator"
        }

        var arguments = [
            "--sdk", sdk,
            "clang",
            "-arch", arch,
            "-dynamiclib",
            "-undefined", "dynamic_lookup",
            "-dead_strip",
            "-Xlinker", "-interposable",
            "-fobjc-arc"
        ]

        if let target = firstRegexCapture(
            #" -target ([^\s]+)"#,
            in: compileCommand
        ) {
            arguments += ["-target", unescape(target)]
        }

        if let developerDir = xcodeDeveloperDirectory() {
            let platformName = platform.lowercased()
            arguments += [
                "-L",
                developerDir +
                    "/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/" +
                    platformName,
                "-rpath", "/usr/lib/swift"
            ]
        }

        arguments += [object, "-o", dylib]
        return arguments
    }

    private func xcodeDeveloperDirectory() -> String? {
        let result = Shell.run(
            executable: "/usr/bin/xcode-select",
            arguments: ["-p"]
        )
        guard result.status == 0 else { return nil }
        return result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cachedCommand(
        for key: String
    ) -> CachedCommand? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return memoryCache[key]
    }

    private func store(
        _ command: CachedCommand,
        for key: String
    ) {
        cacheLock.lock()
        memoryCache[key] = command
        cacheLock.unlock()
    }

    private func invalidate(_ key: String) {
        cacheLock.lock()
        memoryCache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    private func standardized(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
                .standardizedFileURL.path
        }

        let base = projectRoot
            ?? fileManager.currentDirectoryPath
        return URL(fileURLWithPath: base)
            .appendingPathComponent(expanded)
            .standardizedFileURL.path
    }

    private func replacingRegex(
        _ pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(
                value.startIndex..<value.endIndex,
                in: value
            ),
            withTemplate: replacement
        )
    }

    private func firstRegexCapture(
        _ pattern: String,
        in value: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(
                    value.startIndex..<value.endIndex,
                    in: value
                )
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }

        return String(value[range])
    }

    private func regexEscapeShellPath(_ path: String) -> String {
        NSRegularExpression.escapedPattern(for: shellEscapePath(path))
    }

    private func shellEscapePath(_ path: String) -> String {
        path.replacingOccurrences(
            of: #"([ '(){}$&*])"#,
            with: #"\\$1"#,
            options: .regularExpression
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) + "'"
    }

    private func unescape(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\\(.)"#,
            with: "$1",
            options: .regularExpression
        )
    }
}

private struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private enum Shell {
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let currentDirectory {
            process.currentDirectoryURL = URL(
                fileURLWithPath: currentDirectory
            )
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ShellResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error)
            )
        }

        process.waitUntilExit()

        let outData =
            stdout.fileHandleForReading.readDataToEndOfFile()
        let errData =
            stderr.fileHandleForReading.readDataToEndOfFile()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(
                decoding: outData,
                as: UTF8.self
            ),
            stderr: String(
                decoding: errData,
                as: UTF8.self
            )
        )
    }
}
