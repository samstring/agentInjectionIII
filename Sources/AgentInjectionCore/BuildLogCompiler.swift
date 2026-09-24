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

    public struct Diagnostics: Sendable {
        public let derivedDataRoot: String
        public let buildLogCount: Int
        public let newestBuildLog: String?
        public let source: String?
        public let sourceExists: Bool?
        public let compileCommandFound: Bool?
    }

    private struct CachedCommand: Codable {
        let command: String
        let logPath: String
        let workingDirectory: String?
    }

    private let projectRoot: String?
    private let derivedDataRoot: String?
    private let cacheURL: URL
    private let interceptionLogURL: URL
    private let fileManager = FileManager.default
    private let deviceTesting: Bool
    private let deviceLibraries: [String]
    private let settingsLock = NSLock()
    private var selectedXcodePath: String?
    private let cacheLock = NSLock()
    private var memoryCache: [String: CachedCommand] = [:]

    private let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    private lazy var quotedArgumentRegex =
        #"(?:'[^']*'|"[^"]*"|\#(argumentRegex))"#
    private let optionsToRemove =
        #"(-(pch-output-dir|supplementary-output-file-map|emit-((reference-)?dependencies|const-values)|serialize-diagnostics|index-(store|unit-output))(-path)?|(-validate-clang-modules-once )?-clang-build-session-file|-Xcc -ivfsstatcache -Xcc)"#

    public init(
        projectRoot: String? = nil,
        derivedDataRoot: String? = nil,
        cacheRoot: String? = nil,
        interceptionLogPath: String? = nil,
        xcodePath: String? = nil,
        deviceTesting: Bool = false,
        deviceLibraries: [String] = [
            "-framework", "XCTest",
            "-lXCTestSwiftSupport"
        ]
    ) {
        self.projectRoot = projectRoot
        self.derivedDataRoot = derivedDataRoot
        self.selectedXcodePath = xcodePath
        self.deviceTesting = deviceTesting
        self.deviceLibraries = deviceLibraries

        let root: URL
        if let cacheRoot {
            root = URL(
                fileURLWithPath: NSString(
                    string: cacheRoot
                ).expandingTildeInPath
            )
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agentInjectionIII/cache")
        }

        self.cacheURL = root
            .appendingPathComponent("compile-commands.json")
        self.interceptionLogURL = interceptionLogPath.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        } ?? root.appendingPathComponent("frontend-commands.log")

        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(
                [String: CachedCommand].self,
                from: data
           ) {
            self.memoryCache = cached
        }
    }

    public func setXcodePath(
        _ path: String?
    ) {
        settingsLock.lock()
        selectedXcodePath = path
        settingsLock.unlock()
    }

    public func xcodePath() -> String? {
        settingsLock.lock()
        defer { settingsLock.unlock() }

        if let selectedXcodePath {
            return selectedXcodePath
        }

        let result = Shell.run(
            executable: "/usr/bin/xcode-select",
            arguments: ["-p"]
        )
        guard result.status == 0 else {
            return nil
        }

        let developer = result.stdout
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard developer.hasSuffix(
            "/Contents/Developer"
        ) else {
            return nil
        }

        return String(
            developer.dropLast(
                "/Contents/Developer".count
            )
        )
    }

    public func knownSwiftSources(
        maximumLogs: Int = 12
    ) -> [String] {
        ingestInterceptedCommands()
        var sources = Set<String>()

        cacheLock.lock()
        for key in memoryCache.keys {
            if let separator = key.lastIndex(of: "|") {
                let source = String(key[..<separator])
                if source.hasSuffix(".swift") {
                    sources.insert(source)
                }
            }
        }
        cacheLock.unlock()

        for logURL in buildLogsNewestFirst()
            .prefix(maximumLogs) {
            let result = Shell.run(
                executable: "/usr/bin/gunzip",
                arguments: ["-c", logURL.path]
            )
            guard result.status == 0 else {
                continue
            }

            let normalized = result.stdout
                .replacingOccurrences(
                    of: "\r",
                    with: "\n"
                )

            let pattern =
                " -primary-file (\(quotedArgumentRegex))"

            for rawLine in normalized.split(
                separator: "\n",
                omittingEmptySubsequences: true
            ) {
                let line = String(rawLine)
                guard line.contains("swift-frontend"),
                      let token = firstRegexCapture(
                        pattern,
                        in: line
                      )
                else {
                    continue
                }

                let source = standardized(
                    decodeShellToken(token)
                )

                guard source.hasSuffix(".swift"),
                      fileManager.fileExists(
                        atPath: source
                      ) else {
                    continue
                }

                if let projectRoot {
                    let root = standardized(
                        projectRoot
                    )
                    guard source.hasPrefix(
                        root.hasSuffix("/")
                            ? root
                            : root + "/"
                    ) else {
                        continue
                    }
                }

                sources.insert(source)
            }
        }

        return sources.sorted()
    }

    public func intermediatesDirectory() -> URL? {
        guard let newest = buildLogsNewestFirst().first else {
            return nil
        }

        // .../<DerivedData>/<Workspace>/Logs/Build/<file>.xcactivitylog
        let workspaceRoot = newest
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let intermediates = workspaceRoot
            .appendingPathComponent("Build")
            .appendingPathComponent("Intermediates.noindex")

        return fileManager.fileExists(
            atPath: intermediates.path
        ) ? intermediates : nil
    }

    public func diagnostics(
        source: String? = nil,
        platform: String? = nil
    ) -> Diagnostics {
        ingestInterceptedCommands()
        let logs = buildLogsNewestFirst()
        let root: String
        if let derivedDataRoot {
            root = NSString(
                string: derivedDataRoot
            ).expandingTildeInPath
        } else {
            root = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
                .path
        }

        guard let source else {
            return Diagnostics(
                derivedDataRoot: root,
                buildLogCount: logs.count,
                newestBuildLog: logs.first?.path,
                source: nil,
                sourceExists: nil,
                compileCommandFound: nil
            )
        }

        let normalized = standardized(source)
        let exists = fileManager.fileExists(atPath: normalized)
        let requestedPlatform = platform ?? ""
        let command: CachedCommand?
        if exists {
            let exactKey = normalized + "|" + requestedPlatform
            if let cached = cachedCommand(
                for: exactKey
            ) {
                command = cached
            } else if requestedPlatform.isEmpty {
                cacheLock.lock()
                command = memoryCache.first {
                    $0.key.hasPrefix(normalized + "|")
                }?.value
                cacheLock.unlock()
            } else {
                command = locateCompilationCommand(
                    source: normalized,
                    platform: requestedPlatform
                )
            }
        } else {
            command = nil
        }

        return Diagnostics(
            derivedDataRoot: root,
            buildLogCount: logs.count,
            newestBuildLog: logs.first?.path,
            source: normalized,
            sourceExists: exists,
            compileCommandFound: command != nil
        )
    }

    public func interceptionLogPath() -> String {
        interceptionLogURL.path
    }

    public func interceptedCommandCount() -> Int {
        ingestInterceptedCommands()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return memoryCache.values.filter {
            $0.logPath == interceptionLogURL.path
        }.count
    }

    /// Imports compiler invocations captured by the patched swift-frontend
    /// feeder. Each line is: shell-escaped PWD, a tab, then a shell-escaped
    /// compiler command.
    public func ingestInterceptedCommands() {
        guard let contents = try? String(
            contentsOf: interceptionLogURL,
            encoding: .utf8
        ), !contents.isEmpty else {
            return
        }

        var captured: [(String, CachedCommand)] = []

        for rawLine in contents.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ) {
            let line = String(rawLine)
            guard let tab = line.firstIndex(of: "\t") else {
                continue
            }

            let rawWorkingDirectory = String(line[..<tab])
            let command = String(line[line.index(after: tab)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard command.contains("swift-frontend"),
                  command.contains(" -frontend "),
                  command.contains(" -c ") else {
                continue
            }

            let workingDirectory = decodeShellToken(rawWorkingDirectory)
            let platform = interceptedPlatform(from: command)
            let primaries = interceptedPrimaryFiles(from: command)

            for source in primaries {
                let normalized = standardized(source)
                guard normalized.hasSuffix(".swift") else {
                    continue
                }

                captured.append((
                    normalized + "|" + platform,
                    CachedCommand(
                        command: command,
                        logPath: interceptionLogURL.path,
                        workingDirectory: workingDirectory.isEmpty
                            ? projectRoot
                            : workingDirectory
                    )
                ))
            }
        }

        guard !captured.isEmpty else { return }

        cacheLock.lock()
        for (key, value) in captured {
            memoryCache[key] = value
        }
        persistCacheLocked()
        cacheLock.unlock()
    }

    private func interceptedPlatform(
        from command: String
    ) -> String {
        if let captures = firstRegexCaptures(
            #"/SDKs/([A-Za-z]+)[0-9.]*\.sdk"#,
            in: command
        ), let platform = captures.first {
            return platform
        }

        if command.contains("-apple-ios") {
            return command.contains("-simulator")
                ? "iPhoneSimulator"
                : "iPhoneOS"
        }

        return ""
    }

    private func interceptedPrimaryFiles(
        from command: String
    ) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: " -primary-file (\(quotedArgumentRegex))"
        ) else {
            return []
        }

        let range = NSRange(
            command.startIndex..<command.endIndex,
            in: command
        )

        return regex.matches(in: command, range: range)
            .compactMap { match in
                guard match.numberOfRanges > 1,
                      let tokenRange = Range(
                        match.range(at: 1),
                        in: command
                      ) else {
                    return nil
                }
                return decodeShellToken(
                    String(command[tokenRange])
                )
            }
    }

    public func compileAndLink(
        source: String,
        platform: String,
        arch: String
    ) -> Result<Artifact, ControlError> {
        ingestInterceptedCommands()
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
        let usedPersistentOrMemoryCache: Bool

        if let cached = cachedCommand(for: cacheKey) {
            located = cached
            usedPersistentOrMemoryCache = true
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
            usedPersistentOrMemoryCache = false
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

        var compileCommand = makeSingleFileCommand(
            original: located.command,
            source: source,
            object: object
        )

        var temporaryInputs: [String] = []
        switch prepareMissingInputs(
            command: compileCommand,
            source: source,
            activityLogPath: located.logPath
        ) {
        case .success(let prepared):
            compileCommand = prepared.command
            temporaryInputs = prepared.temporaryFiles

        case .failure(let error):
            invalidate(cacheKey)
            return .failure(error)
        }

        defer {
            for path in temporaryInputs {
                try? fileManager.removeItem(atPath: path)
            }
        }

        let compileStart = Date.timeIntervalSinceReferenceDate
        var compileResult = Shell.run(
            executable: "/bin/zsh",
            arguments: ["-lc", compileCommand],
            currentDirectory: located.workingDirectory ?? projectRoot
        )

        if compileResult.status != 0,
           recoverMissingPCH(from: compileResult.combinedOutput) {
            compileResult = Shell.run(
                executable: "/bin/zsh",
                arguments: ["-lc", compileCommand],
                currentDirectory: located.workingDirectory ?? projectRoot
            )
        }

        let compileMs =
            (Date.timeIntervalSinceReferenceDate - compileStart) * 1000

        guard compileResult.status == 0,
              fileManager.fileExists(atPath: object) else {
            invalidate(cacheKey)

            if usedPersistentOrMemoryCache {
                return compileAndLink(
                    source: source,
                    platform: platform,
                    arch: arch
                )
            }

            let diagnostics = parseCompilerDiagnostics(
                compileResult.combinedOutput
            )

            return .failure(
                ControlError(
                    code: "COMPILE_FAILED",
                    message: """
                    Failed to recompile \(source).

                    Command:
                    \(compileCommand)

                    Output:
                    \(compileResult.combinedOutput)
                    """,
                    diagnostics: diagnostics.isEmpty
                        ? nil
                        : diagnostics
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
            currentDirectory: projectRoot,
            environment: xcodeEnvironment()
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

    public func codesign(
        _ artifact: Artifact,
        identity: String
    ) -> Result<Void, ControlError> {
        let identity = identity.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !identity.isEmpty else {
            return .failure(
                ControlError(
                    code: "CODESIGN_IDENTITY_REQUIRED",
                    message: "A code-signing identity is required for physical-device injection."
                )
            )
        }

        var environment: [String: String] = [:]
        if let developer = xcodeDeveloperDirectory() {
            environment["CODESIGN_ALLOCATE"] =
                developer +
                "/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate"
        }

        let result = Shell.run(
            executable: "/usr/bin/codesign",
            arguments: [
                "--force",
                "--sign", identity,
                "--timestamp=none",
                artifact.dylib
            ],
            currentDirectory: projectRoot,
            environment: environment
        )

        guard result.status == 0 else {
            return .failure(
                ControlError(
                    code: "CODESIGN_FAILED",
                    message: """
                    Failed to codesign injection dylib with identity (identity).

                    Output:
                    (result.combinedOutput)
                    """
                )
            )
        }

        return .success(())
    }

    public func remove(_ artifact: Artifact) {
        try? fileManager.removeItem(atPath: artifact.object)
        try? fileManager.removeItem(atPath: artifact.dylib)
    }

    private struct PreparedCompileCommand {
        let command: String
        let temporaryFiles: [String]
    }

    private func prepareMissingInputs(
        command: String,
        source: String,
        activityLogPath: String
    ) -> Result<PreparedCompileCommand, ControlError> {
        guard source.hasSuffix(".swift"),
              let token = firstRegexCapture(
                " -filelist (\(quotedArgumentRegex))",
                in: command
              ) else {
            return .success(
                PreparedCompileCommand(
                    command: command,
                    temporaryFiles: []
                )
            )
        }

        let originalFileList = decodeShellToken(token)
        guard !originalFileList.isEmpty,
              !fileManager.fileExists(atPath: originalFileList) else {
            return .success(
                PreparedCompileCommand(
                    command: command,
                    temporaryFiles: []
                )
            )
        }

        guard activityLogPath.hasSuffix(".xcactivitylog"),
              let recovered = recoverFileList(
                source: source,
                activityLogPath: activityLogPath
              ) else {
            return .failure(
                ControlError(
                    code: "FILELIST_MISSING",
                    message: """
                    Swift compiler file list no longer exists: \(originalFileList).                     Rebuild the app in Xcode, then retry injection.                     EMIT_FRONTEND_COMMAND_LINES=YES is recommended for Debug.
                    """
                )
            )
        }

        let replacement = " -filelist \(shellQuote(recovered))"
        let rewritten = replacingRegex(
            " -filelist \(quotedArgumentRegex)",
            in: command,
            with: replacement
        )

        return .success(
            PreparedCompileCommand(
                command: rewritten,
                temporaryFiles: [recovered]
            )
        )
    }

    private func recoverFileList(
        source: String,
        activityLogPath: String
    ) -> String? {
        let result = Shell.run(
            executable: "/usr/bin/gunzip",
            arguments: ["-c", activityLogPath]
        )
        guard result.status == 0 else { return nil }

        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        let pattern = " -output-file-map (\(quotedArgumentRegex))"

        for rawLine in result.stdout
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.contains(sourceName),
                  let token = firstRegexCapture(pattern, in: line)
            else {
                continue
            }

            let outputMapPath = decodeShellToken(token)
            guard fileManager.fileExists(atPath: outputMapPath),
                  let data = try? Data(
                    contentsOf: URL(fileURLWithPath: outputMapPath)
                  ),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let map = json as? [String: Any]
            else {
                continue
            }

            let keys = Array(map.keys)
            guard keys.contains(source) ||
                    keys.contains(where: {
                        URL(fileURLWithPath: $0).lastPathComponent == sourceName
                    }) else {
                continue
            }

            let directory = "/tmp/agentInjectionIII"
            try? fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )

            let recovered = directory +
                "/filelist-\(UUID().uuidString).txt"
            let contents = keys.sorted().joined(separator: "\n") + "\n"

            do {
                try contents.write(
                    toFile: recovered,
                    atomically: false,
                    encoding: .utf8
                )
                return recovered
            } catch {
                return nil
            }
        }

        return nil
    }

    private func recoverMissingPCH(from output: String) -> Bool {
        guard let missing = firstRegexCapture(
            #"PCH file '([^']+)' not found"#,
            in: output
        ) else {
            return false
        }

        let missingURL = URL(fileURLWithPath: missing)
        let directory = missingURL.deletingLastPathComponent()
        let filename = missingURL.lastPathComponent

        guard let match = firstRegexCaptures(
            #"^(.*-Bridging-Header-swift_)[^-]+(-clang_[^/]+\.pch)$"#,
            in: filename
        ),
        match.count == 2,
        let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let prefix = match[0]
        let suffix = match[1]
        let candidates = files
            .filter {
                let name = $0.lastPathComponent
                return name.hasPrefix(prefix) &&
                    name.hasSuffix(suffix) &&
                    $0.path != missing
            }
            .sorted {
                let left = (
                    try? $0.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                ) ?? .distantPast
                let right = (
                    try? $1.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                ) ?? .distantPast
                return left > right
            }

        guard let candidate = candidates.first else {
            return false
        }

        try? fileManager.removeItem(atPath: missing)

        do {
            try fileManager.createSymbolicLink(
                atPath: missing,
                withDestinationPath: candidate.path
            )
            return true
        } catch {
            return false
        }
    }

    private func locateCompilationCommand(
        source: String,
        platform: String
    ) -> CachedCommand? {
        let escapedSource = shellEscapePath(source)
        let sourceForms = [
            source,
            escapedSource,
            "\"\(source)\"",
            shellQuote(source)
        ]
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

                let containsSource = sourceForms.contains {
                    line.contains($0)
                }

                let isCandidate: Bool
                if isSwift {
                    isCandidate =
                        line.contains(" -primary-file ") &&
                        containsSource
                } else {
                    isCandidate =
                        line.contains(" -c ") &&
                        containsSource
                }

                guard isCandidate else { continue }

                if let command = extractCompilerCommand(
                    from: line,
                    swift: isSwift
                ) {
                    return CachedCommand(
                        command: command,
                        logPath: logURL.path,
                        workingDirectory: projectRoot
                    )
                }
            }
        }

        return nil
    }

    private func buildLogsNewestFirst() -> [URL] {
        let derivedData: URL
        if let derivedDataRoot {
            derivedData = URL(
                fileURLWithPath: NSString(
                    string: derivedDataRoot
                ).expandingTildeInPath
            )
        } else {
            derivedData = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        }

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

    func makeSingleFileCommand(
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
        let sourceTokens = [
            shellEscapePath(source),
            "\"\(source)\"",
            shellQuote(source)
        ]

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

        for token in sourceTokens {
            command = command.replacingOccurrences(
                of: " -primary-file \(token)",
                with: " -agent-primary \(token)"
            )
        }

        command = replacingRegex(
            " -primary-file \(quotedArgumentRegex)",
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

        if let sdkRoot = sdkPath(for: sdk) {
            arguments += ["-isysroot", sdkRoot]
        }

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

        if deviceTesting &&
           !platform.hasSuffix("Simulator") &&
           platform != "MacOSX",
           let developerDir =
                xcodeDeveloperDirectory() {
            let platformDev =
                developerDir +
                "/Platforms/\(platform).platform/Developer"

            arguments += [
                "-F", "/tmp/InjectionNext.Products",
                "-F",
                platformDev + "/Library/Frameworks",
                "-L",
                platformDev + "/usr/lib"
            ]
            arguments += deviceLibraries
        }

        arguments += [object, "-o", dylib]
        return arguments
    }

    private func sdkPath(for sdk: String) -> String? {
        let result = Shell.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", sdk, "--show-sdk-path"],
            environment: xcodeEnvironment()
        )
        guard result.status == 0 else { return nil }
        let path = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func xcodeDeveloperDirectory() -> String? {
        guard let path = xcodePath() else {
            return nil
        }

        return URL(
            fileURLWithPath: path
        )
        .appendingPathComponent("Contents/Developer")
        .path
    }

    private func xcodeEnvironment()
        -> [String: String] {
        guard let developer =
                xcodeDeveloperDirectory() else {
            return [:]
        }

        return [
            "DEVELOPER_DIR": developer
        ]
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
        persistCacheLocked()
        cacheLock.unlock()
    }

    private func invalidate(_ key: String) {
        cacheLock.lock()
        memoryCache.removeValue(forKey: key)
        persistCacheLocked()
        cacheLock.unlock()
    }

    private func persistCacheLocked() {
        let directory = cacheURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(memoryCache)
            try data.write(
                to: cacheURL,
                options: [.atomic]
            )
        } catch {
            // Cache persistence must never make injection itself fail.
        }
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

    func parseCompilerDiagnostics(
        _ output: String
    ) -> [CompilerDiagnostic] {
        var diagnostics: [CompilerDiagnostic] = []
        var seen = Set<String>()

        let locatedPattern =
            #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.*)$"#
        let genericPattern =
            #"^\s*(error|warning|note):\s*(.*)$"#

        for rawLine in output.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ) {
            let line = String(rawLine)

            if let captures = firstRegexCaptures(
                locatedPattern,
                in: line
            ),
            captures.count == 5 {
                let diagnostic = CompilerDiagnostic(
                    file: captures[0],
                    line: Int(captures[1]),
                    column: Int(captures[2]),
                    severity: captures[3],
                    message: captures[4]
                )

                let key = [
                    diagnostic.file ?? "",
                    String(diagnostic.line ?? 0),
                    String(diagnostic.column ?? 0),
                    diagnostic.severity,
                    diagnostic.message
                ].joined(separator: "|")

                if seen.insert(key).inserted {
                    diagnostics.append(diagnostic)
                }
                continue
            }

            if let captures = firstRegexCaptures(
                genericPattern,
                in: line
            ),
            captures.count == 2 {
                let diagnostic = CompilerDiagnostic(
                    severity: captures[0],
                    message: captures[1]
                )
                let key =
                    "|0|0|\(diagnostic.severity)|\(diagnostic.message)"
                if seen.insert(key).inserted {
                    diagnostics.append(diagnostic)
                }
            }
        }

        return diagnostics
    }

    private func firstRegexCaptures(
        _ pattern: String,
        in value: String
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(
                    value.startIndex..<value.endIndex,
                    in: value
                )
              ),
              match.numberOfRanges > 1
        else {
            return nil
        }

        var captures: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(
                match.range(at: index),
                in: value
            ) else {
                return nil
            }
            captures.append(String(value[range]))
        }
        return captures
    }

    private func decodeShellToken(_ token: String) -> String {
        guard token.count >= 2 else {
            return unescape(token)
        }

        if (token.hasPrefix("\"") && token.hasSuffix("\"")) ||
           (token.hasPrefix("'") && token.hasSuffix("'")) {
            return unescape(
                String(token.dropFirst().dropLast())
            )
        }

        return unescape(token)
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
        currentDirectory: String? = nil,
        environment: [String: String] = [:]
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let currentDirectory {
            process.currentDirectoryURL = URL(
                fileURLWithPath: currentDirectory
            )
        }

        if !environment.isEmpty {
            process.environment =
                ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let tmp = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let stdoutURL = tmp.appendingPathComponent(
            "agentInjectionIII-\(token).stdout"
        )
        let stderrURL = tmp.appendingPathComponent(
            "agentInjectionIII-\(token).stderr"
        )

        FileManager.default.createFile(
            atPath: stdoutURL.path,
            contents: nil
        )
        FileManager.default.createFile(
            atPath: stderrURL.path,
            contents: nil
        )

        guard let stdoutHandle = try? FileHandle(
            forWritingTo: stdoutURL
        ),
        let stderrHandle = try? FileHandle(
            forWritingTo: stderrURL
        ) else {
            return ShellResult(
                status: -1,
                stdout: "",
                stderr: "Unable to create process output files."
            )
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ShellResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error)
            )
        }

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let outData =
            (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errData =
            (try? Data(contentsOf: stderrURL)) ?? Data()

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

