import Foundation
import Darwin
import AgentInjectionCore

private struct CLIOptions {
    var socketPath = "/tmp/agentInjectionIII.sock"
    var target: String?
    var arguments: [String] = []
}

private func parseGlobalOptions() -> CLIOptions {
    var options = CLIOptions()
    let input = Array(CommandLine.arguments.dropFirst())

    var index = 0
    while index < input.count {
        if input[index] == "--socket" {
            guard index + 1 < input.count else {
                fatalUsage("--socket requires a path")
            }
            options.socketPath = input[index + 1]
            index += 2
            continue
        }

        if input[index] == "--target" {
            guard index + 1 < input.count else {
                fatalUsage("--target requires a target id")
            }
            options.target = input[index + 1]
            index += 2
            continue
        }

        if input[index] == "--help" || input[index] == "-h" {
            printUsage()
            exit(0)
        }

        options.arguments.append(input[index])
        index += 1
    }

    return options
}

private func printUsage() {
    print("""
    usage:
      injectionctl [--socket PATH] targets
      injectionctl [--socket PATH] [--target ID] status
      injectionctl [--socket PATH] [--target ID] inject FILE [FILE ...]
      injectionctl [--socket PATH] [--target ID] load-dylib DYLIB
      injectionctl [--socket PATH] doctor [SOURCE]
      injectionctl [--socket PATH] [--target ID] screenshot [OUTPUT.png]
      injectionctl [--socket PATH] [--target ID] touch capture
      injectionctl [--socket PATH] [--target ID] touch read
      injectionctl [--socket PATH] [--target ID] touch replay EVENTS.json
      injectionctl [--socket PATH] logs [LIMIT]
      injectionctl [--socket PATH] compiler-state
      injectionctl [--socket PATH] logs clear
      injectionctl [--socket PATH] unhide-symbols
      injectionctl [--socket PATH] prepare-swiftui-source FILE.swift
      injectionctl [--socket PATH] prepare-swiftui-project
      injectionctl [--socket PATH] set-xcode-path /Applications/Xcode.app
      injectionctl [--socket PATH] launch-xcode
      injectionctl [--socket PATH] last-error
      injectionctl [--socket PATH] events [LIMIT]
      injectionctl [--socket PATH] events clear
      injectionctl [--socket PATH] [--target ID] env NAME [VALUE]
      injectionctl [--socket PATH] profile [LIMIT]
      injectionctl [--socket PATH] trace start [FILTER_REGEX]
      injectionctl [--socket PATH] trace scope frameworks [FILTER_REGEX]
      injectionctl [--socket PATH] trace scope uikit [FILTER_REGEX]
      injectionctl [--socket PATH] trace scope swiftui [FILTER_REGEX]
      injectionctl [--socket PATH] trace scope main-all [FILTER_REGEX]
      injectionctl [--socket PATH] trace scope framework NAME [FILTER_REGEX]
      injectionctl [--socket PATH] trace scope package NAME [FILTER_REGEX]
      injectionctl [--socket PATH] trace read [LIMIT]
      injectionctl [--socket PATH] trace stop

    Responses are JSON and commands return a non-zero exit status on failure.
    """)
}

private func fatalUsage(_ message: String) -> Never {
    emit(
        .failure(
            code: "USAGE",
            message: message
        )
    )
    exit(2)
}

private func emit(_ response: ControlResponse) {
    do {
        let data = try ControlCodec.prettyEncoder.encode(response)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        fputs("injectionctl: unable to encode response: \(error)\n", stderr)
    }
}

private func absolutePath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .path
    }

    return URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath
    )
    .appendingPathComponent(expanded)
    .standardizedFileURL
    .path
}

let options = parseGlobalOptions()

guard let command = options.arguments.first else {
    fatalUsage("Missing command.")
}

let request: ControlRequest

switch command {
case "targets":
    guard options.arguments.count == 1 else {
        fatalUsage("targets does not accept positional arguments.")
    }
    request = ControlRequest(action: .targets)

case "status":
    guard options.arguments.count == 1 else {
        fatalUsage("status does not accept positional arguments.")
    }
    request = ControlRequest(
        action: .status,
        target: options.target
    )

case "inject":
    let files = Array(options.arguments.dropFirst()).map(absolutePath)
    guard !files.isEmpty else {
        fatalUsage("inject requires at least one source file.")
    }
    request = ControlRequest(
        action: .inject,
        files: files,
        target: options.target
    )

case "load-dylib":
    guard options.arguments.count == 2 else {
        fatalUsage("load-dylib requires exactly one dylib path.")
    }
    request = ControlRequest(
        action: .loadDylib,
        path: absolutePath(options.arguments[1]),
        target: options.target
    )

case "doctor":
    guard options.arguments.count <= 2 else {
        fatalUsage("doctor accepts at most one source path.")
    }
    request = ControlRequest(
        action: .doctor,
        path: options.arguments.count == 2
            ? absolutePath(options.arguments[1])
            : nil
    )

case "screenshot":
    guard options.arguments.count <= 2 else {
        fatalUsage("screenshot accepts at most one output path.")
    }
    request = ControlRequest(
        action: .screenshot,
        path: options.arguments.count == 2
            ? absolutePath(options.arguments[1])
            : nil,
        target: options.target
    )

case "touch":
    guard options.arguments.count >= 2 else {
        fatalUsage("touch requires capture, read, or replay.")
    }

    switch options.arguments[1] {
    case "capture":
        guard options.arguments.count == 2 else {
            fatalUsage("touch capture does not accept arguments.")
        }
        request = ControlRequest(
            action: .touchCapture,
            target: options.target
        )

    case "read":
        guard options.arguments.count == 2 else {
            fatalUsage("touch read does not accept arguments.")
        }
        request = ControlRequest(
            action: .touchRead,
            target: options.target
        )

    case "replay":
        guard options.arguments.count == 3 else {
            fatalUsage("touch replay requires one JSON file.")
        }

        let path = absolutePath(options.arguments[2])
        guard let payload = try? String(
            contentsOfFile: path,
            encoding: .utf8
        ) else {
            fatalUsage("unable to read touch event JSON file: \(path)")
        }

        request = ControlRequest(
            action: .touchReplay,
            target: options.target,
            payload: payload
        )

    default:
        fatalUsage("Unknown touch command: \(options.arguments[1])")
    }

case "logs":
    if options.arguments.count == 2 &&
       options.arguments[1] == "clear" {
        request = ControlRequest(
            action: .clearLogs
        )
    } else {
        guard options.arguments.count <= 2 else {
            fatalUsage("logs accepts at most one LIMIT or 'clear'.")
        }

        var limit: Int?
        if options.arguments.count == 2 {
            guard let parsed = Int(options.arguments[1]),
                  parsed > 0 else {
                fatalUsage("logs limit must be a positive integer.")
            }
            limit = parsed
        }

        request = ControlRequest(
            action: .logs,
            limit: limit
        )
    }

case "unhide-symbols":
    guard options.arguments.count == 1 else {
        fatalUsage("unhide-symbols does not accept arguments.")
    }
    request = ControlRequest(
        action: .unhideSymbols
    )

case "prepare-swiftui-source":
    guard options.arguments.count == 2 else {
        fatalUsage("prepare-swiftui-source requires one Swift file.")
    }
    request = ControlRequest(
        action: .prepareSwiftUISource,
        path: absolutePath(
            options.arguments[1]
        )
    )

case "prepare-swiftui-project":
    guard options.arguments.count == 1 else {
        fatalUsage("prepare-swiftui-project does not accept arguments.")
    }
    request = ControlRequest(
        action: .prepareSwiftUIProject
    )

case "set-xcode-path":
    guard options.arguments.count == 2 else {
        fatalUsage("set-xcode-path requires an Xcode.app path.")
    }
    request = ControlRequest(
        action: .setXcodePath,
        path: absolutePath(
            options.arguments[1]
        )
    )

case "launch-xcode":
    guard options.arguments.count == 1 else {
        fatalUsage("launch-xcode does not accept arguments.")
    }
    request = ControlRequest(
        action: .launchXcode
    )

case "last-error":
    guard options.arguments.count == 1 else {
        fatalUsage("last-error does not accept arguments.")
    }
    request = ControlRequest(
        action: .getLastError
    )

case "events":
    if options.arguments.count == 2 &&
       options.arguments[1] == "clear" {
        request = ControlRequest(
            action: .clearEvents
        )
    } else {
        guard options.arguments.count <= 2 else {
            fatalUsage("events accepts at most one LIMIT or 'clear'.")
        }

        var limit: Int?
        if options.arguments.count == 2 {
            guard let parsed = Int(options.arguments[1]),
                  parsed > 0 else {
                fatalUsage("events limit must be a positive integer.")
            }
            limit = parsed
        }

        request = ControlRequest(
            action: .events,
            limit: limit
        )
    }

case "env":
    guard options.arguments.count == 2 ||
          options.arguments.count == 3 else {
        fatalUsage("env requires NAME and optional VALUE. Omit VALUE to unset.")
    }

    let name = options.arguments[1]
    guard name.hasPrefix("INJECTION_") else {
        fatalUsage("env only accepts INJECTION_* names.")
    }

    request = ControlRequest(
        action: .setRuntimeEnv,
        target: options.target,
        environment: [
            name: options.arguments.count == 3
                ? options.arguments[2]
                : nil
        ]
    )

case "compiler-state":
    guard options.arguments.count == 1 else {
        fatalUsage("compiler-state does not accept arguments.")
    }
    request = ControlRequest(
        action: .compilerState
    )

case "profile":
    guard options.arguments.count <= 2 else {
        fatalUsage("profile accepts at most one LIMIT.")
    }

    var limit: Int?
    if options.arguments.count == 2 {
        guard let parsed = Int(options.arguments[1]),
              parsed > 0 else {
            fatalUsage("profile limit must be a positive integer.")
        }
        limit = parsed
    }

    request = ControlRequest(
        action: .profileSnapshot,
        limit: limit
    )

case "trace":
    guard options.arguments.count >= 2 else {
        fatalUsage("trace requires start, read, or stop.")
    }

    switch options.arguments[1] {
    case "scope":
        guard options.arguments.count >= 3 else {
            fatalUsage("trace scope requires a scope name.")
        }

        let scope = options.arguments[2]
        let namedScopes = Set(["framework", "package"])
        let simpleScopes = Set([
            "frameworks", "uikit",
            "swiftui", "main-all"
        ])

        var name: String?
        var filter: String?

        if namedScopes.contains(scope) {
            guard options.arguments.count == 4 ||
                  options.arguments.count == 5 else {
                fatalUsage("trace scope \(scope) requires NAME and optional FILTER_REGEX.")
            }
            name = options.arguments[3]
            if options.arguments.count == 5 {
                filter = options.arguments[4]
            }
        } else if simpleScopes.contains(scope) {
            guard options.arguments.count == 3 ||
                  options.arguments.count == 4 else {
                fatalUsage("trace scope \(scope) accepts optional FILTER_REGEX.")
            }
            if options.arguments.count == 4 {
                filter = options.arguments[3]
            }
        } else {
            fatalUsage("Unknown trace scope: \(scope)")
        }

        request = ControlRequest(
            action: .traceScope,
            filter: filter,
            scope: scope,
            name: name
        )

    case "start":
        guard options.arguments.count <= 3 else {
            fatalUsage("trace start accepts at most one filter regex.")
        }
        request = ControlRequest(
            action: .traceStart,
            filter: options.arguments.count == 3
                ? options.arguments[2]
                : nil
        )

    case "read":
        guard options.arguments.count <= 3 else {
            fatalUsage("trace read accepts at most one limit.")
        }

        var limit: Int?
        if options.arguments.count == 3 {
            guard let parsed = Int(options.arguments[2]),
                  parsed > 0 else {
                fatalUsage("trace read limit must be a positive integer.")
            }
            limit = parsed
        }

        request = ControlRequest(
            action: .traceRead,
            limit: limit
        )

    case "stop":
        guard options.arguments.count == 2 else {
            fatalUsage("trace stop does not accept arguments.")
        }
        request = ControlRequest(action: .traceStop)

    default:
        fatalUsage("Unknown trace command: \(options.arguments[1])")
    }

default:
    fatalUsage("Unknown command: \(command)")
}

do {
    let client = UnixSocketClient(socketPath: options.socketPath)
    let response = try client.send(request)
    emit(response)
    exit(response.ok ? 0 : 4)
} catch {
    emit(
        .failure(
            id: request.id,
            code: "DAEMON_UNAVAILABLE",
            message: String(describing: error)
        )
    )
    exit(3)
}
