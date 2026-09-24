import Foundation

/// Headless source recompilation for Xcode projects.
///
/// The implementation intentionally reuses the same high-level strategy as
/// InjectionLite/InjectionNext: locate the original Xcode compiler command in
/// .xcactivitylog, reduce it to a single-primary-file compilation, produce an
/// object file, then link that object as a dylib for the Injection runtime.
///
/// The log parsing/link-command approach is adapted from John Holdsworth's
/// InjectionLite/InjectionNext projects (MIT). See THIRD_PARTY_NOTICES.md.
final class HeadlessXcodeCompiler {
    struct BuildArtifact {
        let dylibPath: String
        let compileOutput: String
    }

    struct CommandTransformer {
        static let shellTokenPattern = #"(?:'[^']*'|"[^"]*"|[^\s\\]*(?:\\.[^\s\\]*)*)"#

        static func compilerCommand(
            from logLine: String,
            source: String
        ) -> String? {
            let markers = [
                "/usr/bin/swift-frontend",
                "/usr/bin/swiftc",
                "/usr/bin/clang"
            ]

            guard let markerRange = markers
                .compactMap({ logLine.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else {
                return nil
            }

            var start = markerRange.lowerBound
            while start > logLine.startIndex {
                let previous = logLine.index(before: start)
                let character = logLine[previous]
                if character == " " || character == "\t" {
                    break
                }
                start = previous
            }

            let command = String(logLine[start...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let isSwift = source.hasSuffix(".swift")
            if isSwift {
                guard command.contains("swift-frontend") ||
                      command.contains("swiftc") else {
                    return nil
                }
            } else {
                guard command.contains("/clang") else {
                    return nil
                }
            }

            return command
        }

        static func prepare(
            command: String,
            source: String,
            objectPath: String
        ) -> String? {
            if source.hasSuffix(".swift") {
                return prepareSwift(
                    command: command,
                    source: source,
                    objectPath: objectPath
                )
            }

            return prepareClang(
                command: command,
                objectPath: objectPath
            )
        }

        static func extractSDKPath(
            from command: String
        ) -> String? {
            let pattern = #"(?:-sdk|-isysroot)\s+("# + shellTokenPattern + #")"#
            guard let match = firstMatch(pattern, in: command, group: 1) else {
                return nil
            }
            return unescapeShellToken(match)
        }

        static func inferPlatform(
            sdkPath: String
        ) -> String? {
            let pattern = #"/Platforms/([^/]+)\.platform/"#
            return firstMatch(pattern, in: sdkPath, group: 1)
        }

        static func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private static func prepareSwift(
            command: String,
            source: String,
            objectPath: String
        ) -> String? {
            var result = command

            result = removeOptionWithValue("-o", from: result)
            result = removeOptionWithValue("-serialize-diagnostics-path", from: result)
            result = removeOptionWithValue("-emit-dependencies-path", from: result)
            result = removeOptionWithValue("-emit-reference-dependencies-path", from: result)
            result = removeOptionWithValue("-emit-const-values-path", from: result)
            result = removeOptionWithValue("-index-store-path", from: result)
            result = removeOptionWithValue("-index-unit-output-path", from: result)
            result = removeOptionWithValue("-supplementary-output-file-map", from: result)

            result = result.replacingOccurrences(
                of: " -frontend-parseable-output",
                with: ""
            )
            result = result.replacingOccurrences(
                of: " -emit-object",
                with: " -c"
            )

            let primaryPattern = #"\s-primary-file\s+("# + shellTokenPattern + #")"#
            guard let regex = try? NSRegularExpression(pattern: primaryPattern) else {
                return nil
            }

            let nsResult = result as NSString
            let matches = regex.matches(
                in: result,
                range: NSRange(location: 0, length: nsResult.length)
            )

            var matchingPrimaryFound = false
            var mutable = result

            for match in matches.reversed() {
                guard match.numberOfRanges > 1 else { continue }
                let token = nsResult.substring(with: match.range(at: 1))
                let decoded = unescapeShellToken(token)
                let samePath = standardized(decoded) == standardized(source)

                if samePath && !matchingPrimaryFound {
                    matchingPrimaryFound = true
                    continue
                }

                if let range = Range(match.range(at: 0), in: mutable) {
                    mutable.removeSubrange(range)
                } else {
                    let current = mutable as NSString
                    if match.range(at: 0).location + match.range(at: 0).length <= current.length {
                        mutable = current.replacingCharacters(
                            in: match.range(at: 0),
                            with: ""
                        )
                    }
                }
            }

            if !matchingPrimaryFound {
                mutable += " -primary-file " + shellQuote(source)
            }

            if !mutable.contains(" -c ") &&
               !mutable.hasSuffix(" -c") {
                mutable += " -c"
            }

            mutable += " -o " + shellQuote(objectPath)
            mutable += " -DINJECTING"

            return mutable
        }

        private static func prepareClang(
            command: String,
            objectPath: String
        ) -> String {
            var result = removeOptionWithValue("-o", from: command)

            if !result.contains(" -c ") &&
               !result.hasSuffix(" -c") {
                result += " -c"
            }

            result += " -o " + shellQuote(objectPath)
            result += " -DINJECTING -Xclang -fno-validate-pch"
            return result
        }

        private static func removeOptionWithValue(
            _ option: String,
            from command: String
        ) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: option)
            let pattern = #"\s"# + escaped + #"\s+"# + shellTokenPattern
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return command
            }

            let range = NSRange(
                location: 0,
                length: (command as NSString).length
            )
            return regex.stringByReplacingMatches(
                in: command,
                range: range,
                withTemplate: ""
            )
        }

        private static func firstMatch(
            _ pattern: String,
            in string: String,
            group: Int
        ) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }

            let ns = string as NSString
            guard let match = regex.firstMatch(
                in: string,
                range: NSRange(location: 0, length: ns.length)
            ),
            match.numberOfRanges > group,
            match.range(at: group).location != NSNotFound else {
                return nil
            }

            return ns.substring(with: match.range(at: group))
        }

        private static func unescapeShellToken(
            _ token: String
        ) -> String {
            var value = token

            if value.count >= 2,
               (value.hasPrefix("'") && value.hasSuffix("'") ||
                value.hasPrefix(""") && value.hasSuffix(""")) {
                value.removeFirst()
                value.removeLast()
            }

            var result = ""
            var escaping = false

            for character in value {
                if escaping {
                    result.append(character)
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }

            if escaping {
                result.append("\\")
            }

            return result
        }

        private static func standardized(
            _ path: String
        ) -> String {
            URL(fileURLWithPath: path)
                .standardizedFileURL
                .path
        }
    }

    private let projectRoot: String?
    private let derivedDataRoot: String
    private let lock = NSLock()
    private var commandCache = [String: String]()

    init(
        projectRoot: String?,
        derivedDataRoot: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.derivedDataRoot = derivedDataRoot
            ?? NSString(
                string: "~/Library/Developer/Xcode/DerivedData"
            ).expandingTildeInPath
    }

    func buildDylib(
        source: String,
        runtime: InjectionRuntimeStatus
    ) -> Result<BuildArtifact, ControlError> {
        let normalizedSource = normalize(source)

        guard FileManager.default.fileExists(atPath: normalizedSource) else {
            return .failure(
                ControlError(
                    code: "SOURCE_NOT_FOUND",
                    message: "Source file does not exist: \(normalizedSource)"
                )
            )
        }

        guard let platform = runtime.platform,
              let arch = runtime.arch else {
            return .failure(
                ControlError(
                    code: "RUNTIME_METADATA_UNAVAILABLE",
                    message: "Runtime has not reported platform/architecture yet."
                )
            )
        }

        do {
            return .success(
                try buildDylibThrowing(
                    source: normalizedSource,
                    platform: platform,
                    arch: arch,
                    allowCache: true
                )
            )
        } catch let error as ControlError {
            invalidateCommand(for: normalizedSource)

            do {
                return .success(
                    try buildDylibThrowing(
                        source: normalizedSource,
                        platform: platform,
                        arch: arch,
                        allowCache: false
                    )
                )
            } catch let retryError as ControlError {
                return .failure(retryError)
            } catch {
                return .failure(
                    ControlError(
                        code: "COMPILER_INTERNAL_ERROR",
                        message: String(describing: error)
                    )
                )
            }
        } catch {
            return .failure(
                ControlError(
                    code: "COMPILER_INTERNAL_ERROR",
                    message: String(describing: error)
                )
            )
        }
    }

    private func buildDylibThrowing(
        source: String,
        platform: String,
        arch: String,
        allowCache: Bool
    ) throws -> BuildArtifact {
        let command: String

        if allowCache,
           let cached = cachedCommand(for: source) {
            command = cached
        } else {
            guard let discovered = discoverCommand(
                for: source,
                platform: platform
            ) else {
                throw ControlError(
                    code: "COMPILER_COMMAND_NOT_FOUND",
                    message: """
                    Could not find the Xcode compiler command for \(source).                     Build the target once after setting EMIT_FRONTEND_COMMAND_LINES=YES.
                    """
                )
            }
            command = discovered
            storeCommand(discovered, for: source)
        }

        let workDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(
            "agentInjectionIII-" + UUID().uuidString,
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let objectPath = workDirectory
            .appendingPathComponent("injected.o")
            .path
        let dylibPath = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(
            "agent_injection_" + UUID().uuidString + ".dylib"
        )
        .path

        guard let compileCommand = CommandTransformer.prepare(
            command: command,
            source: source,
            objectPath: objectPath
        ) else {
            throw ControlError(
                code: "COMPILER_COMMAND_TRANSFORM_FAILED",
                message: "Unable to transform Xcode command for \(source)."
            )
        }

        let compile = runShell(compileCommand)
        guard compile.status == 0,
              FileManager.default.fileExists(atPath: objectPath) else {
            throw ControlError(
                code: "COMPILE_FAILED",
                message: compile.output.isEmpty
                    ? "Compiler exited with status \(compile.status)."
                    : compile.output
            )
        }

        guard let sdkPath = CommandTransformer.extractSDKPath(
            from: command
        ) else {
            throw ControlError(
                code: "SDK_NOT_FOUND",
                message: "Unable to extract SDK path from the original compiler command."
            )
        }

        let effectivePlatform =
            CommandTransformer.inferPlatform(sdkPath: sdkPath)
            ?? platform

        let link = linkObject(
            objectPath: objectPath,
            dylibPath: dylibPath,
            sdkPath: sdkPath,
            platform: effectivePlatform,
            arch: arch
        )

        guard link.status == 0,
              FileManager.default.fileExists(atPath: dylibPath) else {
            throw ControlError(
                code: "LINK_FAILED",
                message: link.output.isEmpty
                    ? "Linker exited with status \(link.status)."
                    : link.output
            )
        }

        return BuildArtifact(
            dylibPath: dylibPath,
            compileOutput: compile.output
        )
    }

    private func discoverCommand(
        for source: String,
        platform: String
    ) -> String? {
        let basename = URL(fileURLWithPath: source).lastPathComponent
        let escapedSource = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: " ", with: "\\ ")

        for logURL in recentBuildLogs(limit: 80) {
            let result = runProcess(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    /usr/bin/gunzip -c "$AGENT_LOG" 2>/dev/null |                     /usr/bin/tr '\\r' '\\n' |                     /usr/bin/grep -F -- "$AGENT_NEEDLE"
                    """
                ],
                environment: [
                    "AGENT_LOG": logURL.path,
                    "AGENT_NEEDLE": basename
                ]
            )

            guard !result.output.isEmpty else { continue }

            let lines = result.output
                .components(separatedBy: .newlines)
                .filter {
                    !$0.contains("builtin-ScanDependencies") &&
                    !$0.contains("llvmcas://")
                }

            let exact = lines.filter {
                $0.contains(source) || $0.contains(escapedSource)
            }
            let candidates = exact.isEmpty ? lines : exact

            for line in candidates.reversed() {
                guard let command = CommandTransformer.compilerCommand(
                    from: line,
                    source: source
                ) else {
                    continue
                }

                if source.hasSuffix(".swift") {
                    if command.contains("-primary-file") ||
                       command.contains("builtin-Swift-Compilation") {
                        if platform.isEmpty ||
                           command.contains("SDKs/\(platform)") ||
                           command.contains("/\(platform).platform/") {
                            return command
                        }
                    }
                } else if command.contains(" -c ") ||
                          command.contains(" -c\t") {
                    return command
                }
            }
        }

        return nil
    }

    private func recentBuildLogs(
        limit: Int
    ) -> [URL] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: derivedDataRoot)

        guard let projects = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var logs = [(url: URL, date: Date)]()

        for project in projects {
            let buildLogs = project
                .appendingPathComponent("Logs")
                .appendingPathComponent("Build")

            guard let files = try? fm.contentsOfDirectory(
                at: buildLogs,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where file.pathExtension == "xcactivitylog" {
                let date = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast

                logs.append((file, date))
            }
        }

        return logs
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.url)
    }

    private func linkObject(
        objectPath: String,
        dylibPath: String,
        sdkPath: String,
        platform: String,
        arch: String
    ) -> ProcessResult {
        let xcodeDev = xcodeDeveloperDirectory(
            fromSDKPath: sdkPath
        )
        let clang = xcodeDev
            + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        let toolchain = xcodeDev
            + "/Toolchains/XcodeDefault.xctoolchain"

        let minimumFlag: String?
        switch platform {
        case "iPhoneSimulator":
            minimumFlag = "-mios-simulator-version-min=9.0"
        case "iPhoneOS":
            minimumFlag = "-miphoneos-version-min=9.0"
        case "AppleTVSimulator":
            minimumFlag = "-mtvos-simulator-version-min=9.0"
        case "AppleTVOS":
            minimumFlag = "-mtvos-version-min=9.0"
        default:
            minimumFlag = nil
        }

        var arguments = [
            "-arch", arch,
            "-Xlinker", "-dylib",
            "-isysroot", sdkPath
        ]

        if let minimumFlag {
            arguments.append(minimumFlag)
        }

        let swiftPlatform = platform.lowercased()
        arguments += [
            "-L", toolchain + "/usr/lib/swift/" + swiftPlatform,
            "-undefined", "dynamic_lookup",
            "-dead_strip",
            "-Xlinker", "-objc_abi_version",
            "-Xlinker", "2",
            "-Xlinker", "-interposable",
            "-fobjc-arc",
            "-rpath", "/usr/lib/swift",
            "-rpath", toolchain + "/usr/lib/swift-5.5/" + swiftPlatform,
            objectPath,
            "-o", dylibPath
        ]

        return runProcess(
            executable: clang,
            arguments: arguments
        )
    }

    private func xcodeDeveloperDirectory(
        fromSDKPath sdkPath: String
    ) -> String {
        let marker = "/Platforms/"
        if let range = sdkPath.range(of: marker) {
            return String(sdkPath[..<range.lowerBound])
        }

        if let developerDir =
            ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            return developerDir
        }

        return "/Applications/Xcode.app/Contents/Developer"
    }

    private func normalize(
        _ path: String
    ) -> String {
        let expanded = NSString(string: path).expandingTildeInPath

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
                .standardizedFileURL
                .path
        }

        let base = projectRoot
            ?? FileManager.default.currentDirectoryPath

        return URL(fileURLWithPath: base)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    private func cachedCommand(
        for source: String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return commandCache[source]
    }

    private func storeCommand(
        _ command: String,
        for source: String
    ) {
        lock.lock()
        commandCache[source] = command
        lock.unlock()
    }

    private func invalidateCommand(
        for source: String
    ) {
        lock.lock()
        commandCache.removeValue(forKey: source)
        lock.unlock()
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private func runShell(
        _ command: String
    ) -> ProcessResult {
        runProcess(
            executable: "/bin/sh",
            arguments: ["-c", command]
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: -1,
                output: String(describing: error)
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

public final class HeadlessInjectionBackend: InjectionBackend {
    public let name = "injectionnext-headless"

    private let runtimeServer: InjectionNextRuntimeServer
    private let compiler: HeadlessXcodeCompiler

    public init(
        runtimeServer: InjectionNextRuntimeServer,
        projectRoot: String? = nil,
        derivedDataRoot: String? = nil
    ) {
        self.runtimeServer = runtimeServer
        self.compiler = HeadlessXcodeCompiler(
            projectRoot: projectRoot,
            derivedDataRoot: derivedDataRoot
        )
    }

    public func status() -> BackendStatus {
        let runtime = runtimeServer.status()

        var runtimeDetail = "Listening for InjectionNext runtime on 127.0.0.1:\(runtimeServer.port)."
        if runtime.connected {
            runtimeDetail = "Runtime connected"
            if let platform = runtime.platform {
                runtimeDetail += " platform=\(platform)"
            }
            if let arch = runtime.arch {
                runtimeDetail += " arch=\(arch)"
            }
        }

        return BackendStatus(
            name: name,
            ready: runtime.connected,
            appConnected: runtime.connected,
            capabilities: [
                "status",
                "inject",
                "load-dylib",
                "xcode-build-log-compiler"
            ],
            detail: runtimeDetail
        )
    }

    public func inject(
        files: [String]
    ) -> BackendInjectionResponse {
        let runtime = runtimeServer.status()

        guard runtime.connected else {
            let results = files.map {
                InjectionResult(
                    file: $0,
                    compiled: false,
                    injected: false,
                    message: "No InjectionNext runtime is connected."
                )
            }
            return BackendInjectionResponse(
                results: results,
                error: ControlError(
                    code: "RUNTIME_NOT_CONNECTED",
                    message: "Launch the DEBUG app with the InjectionNext client runtime enabled."
                )
            )
        }

        var results = [InjectionResult]()
        var firstError: ControlError?

        for source in files {
            switch compiler.buildDylib(
                source: source,
                runtime: runtime
            ) {
            case .success(let artifact):
                let runtimeResult = runtimeServer.loadDylib(
                    path: artifact.dylibPath
                )
                try? FileManager.default.removeItem(
                    atPath: artifact.dylibPath
                )

                results.append(
                    InjectionResult(
                        file: source,
                        compiled: true,
                        injected: runtimeResult.injected,
                        message: runtimeResult.message
                    )
                )

                if !runtimeResult.injected && firstError == nil {
                    firstError = ControlError(
                        code: "RUNTIME_INJECTION_FAILED",
                        message: runtimeResult.message
                            ?? "Runtime failed to load the compiled dylib."
                    )
                }

            case .failure(let error):
                results.append(
                    InjectionResult(
                        file: source,
                        compiled: false,
                        injected: false,
                        message: error.message
                    )
                )
                if firstError == nil {
                    firstError = error
                }
            }
        }

        return BackendInjectionResponse(
            results: results,
            error: firstError
        )
    }

    public func loadDylib(
        path: String
    ) -> BackendInjectionResponse {
        let result = runtimeServer.loadDylib(path: path)

        return BackendInjectionResponse(
            results: [result],
            error: result.injected
                ? nil
                : ControlError(
                    code: "DYLIB_INJECTION_FAILED",
                    message: result.message
                        ?? "Runtime failed to inject dylib."
                )
        )
    }
}
