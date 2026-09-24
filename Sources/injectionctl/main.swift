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
      injectionctl [--socket PATH] logs clear
      injectionctl [--socket PATH] trace start [FILTER_REGEX]
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

case "trace":
    guard options.arguments.count >= 2 else {
        fatalUsage("trace requires start, read, or stop.")
    }

    switch options.arguments[1] {
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
