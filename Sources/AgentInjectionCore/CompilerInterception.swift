import Foundation
import Darwin

public final class CompilerInterceptionManager {
    private static let linkedTools = [
        "swift",
        "swiftc",
        "swift-symbolgraph-extract",
        "swift-api-digester",
        "swift-cache-tool"
    ]

    private let compiler: BuildLogCompiler
    private let fileManager = FileManager.default

    public init(compiler: BuildLogCompiler) {
        self.compiler = compiler
    }

    public func state() -> CompilerStateResult {
        let xcodePath = compiler.xcodePath()
        guard let xcodePath else {
            return CompilerStateResult(
                xcodePath: nil,
                frontendPath: nil,
                patchedFrontendPath: nil,
                intercepted: false,
                commandSource: "build-log",
                note: "No selected Xcode toolchain."
            )
        }

        let frontend = Self.frontendURL(
            xcodePath: xcodePath
        )
        let saved = URL(
            fileURLWithPath: frontend.path + ".save"
        )
        let intercepted = fileManager.fileExists(
            atPath: saved.path
        )

        return CompilerStateResult(
            xcodePath: xcodePath,
            frontendPath: frontend.path,
            patchedFrontendPath: saved.path,
            intercepted: intercepted,
            commandSource: intercepted
                ? "intercepted+build-log-fallback"
                : "build-log",
            note: intercepted
                ? "swift-frontend is patched; captured commands: \(compiler.interceptedCommandCount()), log: \(compiler.interceptionLogPath())"
                : "Compiler interception is disabled."
        )
    }

    public func setEnabled(
        _ enabled: Bool
    ) -> Result<CompilerStateResult, ControlError> {
        guard let xcodePath = compiler.xcodePath() else {
            return .failure(
                ControlError(
                    code: "XCODE_NOT_FOUND",
                    message: "No selected Xcode.app could be resolved."
                )
            )
        }

        let bin = Self.binURL(
            xcodePath: xcodePath
        )
        let frontend = bin.appendingPathComponent(
            "swift-frontend"
        )
        let saved = URL(
            fileURLWithPath: frontend.path + ".save"
        )

        do {
            if enabled {
                guard !fileManager.fileExists(
                    atPath: saved.path
                ) else {
                    return .success(state())
                }

                guard fileManager.isWritableFile(
                    atPath: bin.path
                ) else {
                    return .failure(
                        ControlError(
                            code: "TOOLCHAIN_NOT_WRITABLE",
                            message: "Xcode toolchain is not writable: \(bin.path)"
                        )
                    )
                }

                try fileManager.moveItem(
                    at: frontend,
                    to: saved
                )

                do {
                    try Self.writeFeeder(
                        to: frontend,
                        logPath: compiler.interceptionLogPath()
                    )
                    try Self.rewireTools(
                        in: bin,
                        destination: "swift-frontend.save"
                    )
                } catch {
                    try? fileManager.removeItem(
                        at: frontend
                    )
                    try? fileManager.moveItem(
                        at: saved,
                        to: frontend
                    )
                    throw error
                }
            } else {
                guard fileManager.fileExists(
                    atPath: saved.path
                ) else {
                    return .success(state())
                }

                guard fileManager.isWritableFile(
                    atPath: bin.path
                ) else {
                    return .failure(
                        ControlError(
                            code: "TOOLCHAIN_NOT_WRITABLE",
                            message: "Xcode toolchain is not writable: \(bin.path)"
                        )
                    )
                }

                try? fileManager.removeItem(
                    at: frontend
                )
                try fileManager.moveItem(
                    at: saved,
                    to: frontend
                )
                try Self.rewireTools(
                    in: bin,
                    destination: "swift-frontend"
                )
            }

            return .success(state())
        } catch {
            return .failure(
                ControlError(
                    code: "COMPILER_INTERCEPTION_FAILED",
                    message: "Unable to \(enabled ? "patch" : "unpatch") compiler: \(error)"
                )
            )
        }
    }

    private static func binURL(
        xcodePath: String
    ) -> URL {
        URL(fileURLWithPath: xcodePath)
            .appendingPathComponent(
                "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
            )
    }

    private static func frontendURL(
        xcodePath: String
    ) -> URL {
        binURL(xcodePath: xcodePath)
            .appendingPathComponent(
                "swift-frontend"
            )
    }

    private static func rewireTools(
        in bin: URL,
        destination: String
    ) throws {
        for tool in linkedTools {
            let url = bin.appendingPathComponent(
                tool
            )
            try? FileManager.default.removeItem(
                at: url
            )

            guard symlink(
                destination,
                url.path
            ) == 0 else {
                throw ControlError(
                    code: "COMPILER_SYMLINK_FAILED",
                    message: "symlink(\(tool)) failed: \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    private static func writeFeeder(
        to frontend: URL,
        logPath: String
    ) throws {
        let logDirectory = URL(
            fileURLWithPath: logPath
        ).deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        let quotedLog = shellSingleQuote(
            logPath
        )

        // Keep this deliberately small. The real compiler remains next to the
        // script as swift-frontend.save, exactly like InjectionNext.
        let script = """
        #!/bin/zsh
        set +e
        {
          printf '%q\\t' "$PWD"
          printf '%q ' "$0.save" "$@"
          printf '\\n'
        } >> \(quotedLog)
        exec "$0.save" "$@"
        """

        try script.write(
            to: frontend,
            atomically: true,
            encoding: .utf8
        )

        guard chmod(frontend.path, 0o755) == 0 else {
            throw ControlError(
                code: "COMPILER_FEEDER_CHMOD_FAILED",
                message: "chmod failed: \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func shellSingleQuote(
        _ value: String
    ) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) + "'"
    }
}
