import Foundation
import Darwin
import AgentInjectionCore

private struct CLIOptions {
    var socketPath = "/tmp/agentInjectionIII.sock"
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
      injectionctl [--socket PATH] status
      injectionctl [--socket PATH] inject FILE [FILE ...]
      injectionctl [--socket PATH] load-dylib DYLIB
      injectionctl [--socket PATH] doctor [SOURCE]

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
case "status":
    guard options.arguments.count == 1 else {
        fatalUsage("status does not accept positional arguments.")
    }
    request = ControlRequest(action: .status)

case "inject":
    let files = Array(options.arguments.dropFirst()).map(absolutePath)
    guard !files.isEmpty else {
        fatalUsage("inject requires at least one source file.")
    }
    request = ControlRequest(action: .inject, files: files)

case "load-dylib":
    guard options.arguments.count == 2 else {
        fatalUsage("load-dylib requires exactly one dylib path.")
    }
    request = ControlRequest(
        action: .loadDylib,
        path: absolutePath(options.arguments[1])
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
