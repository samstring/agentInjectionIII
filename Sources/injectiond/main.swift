import Foundation
import Darwin
import AgentInjectionCore

private struct DaemonOptions {
    var socketPath = "/tmp/agentInjectionIII.sock"
    var projectRoot: String?
    var runtimePort: UInt16 = 8887
}

private func parseOptions() -> DaemonOptions {
    var options = DaemonOptions()
    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0

    while index < arguments.count {
        switch arguments[index] {
        case "--socket":
            guard index + 1 < arguments.count else {
                fatalUsage("--socket requires a path")
            }
            options.socketPath = arguments[index + 1]
            index += 2

        case "--project":
            guard index + 1 < arguments.count else {
                fatalUsage("--project requires a path")
            }
            options.projectRoot = arguments[index + 1]
            index += 2

        case "--runtime-port":
            guard index + 1 < arguments.count,
                  let port = UInt16(arguments[index + 1]),
                  port > 0 else {
                fatalUsage("--runtime-port requires a valid TCP port")
            }
            options.runtimePort = port
            index += 2

        case "--help", "-h":
            printUsage()
            exit(0)

        default:
            fatalUsage("Unknown argument: \(arguments[index])")
        }
    }

    return options
}

private func printUsage() {
    print("""
    usage: injectiond [--socket PATH] [--project ROOT] [--runtime-port PORT]

      --socket PATH       Unix domain socket path for injectionctl.
                          Default: /tmp/agentInjectionIII.sock
      --project ROOT      Project root used to resolve relative source paths.
      --runtime-port PORT InjectionNext client runtime TCP port.
                          Default: 8887
    """)
}

private func fatalUsage(_ message: String) -> Never {
    fputs("injectiond: \(message)\n", stderr)
    printUsage()
    exit(2)
}

let options = parseOptions()
let runtimeServer = InjectionNextRuntimeServer(
    port: options.runtimePort
)

do {
    try runtimeServer.start()
} catch {
    fputs("injectiond: unable to start InjectionNext runtime server: \(error)\n", stderr)
    exit(1)
}

let backend = InjectionNextRuntimeBackend(
    runtimeServer: runtimeServer,
    projectRoot: options.projectRoot
)
let router = ControlRouter(
    socketPath: options.socketPath,
    backend: backend
)
let server = UnixSocketServer(
    socketPath: options.socketPath,
    handler: router.handle
)

fputs(
    "agentInjectionIII injectiond \(ControlRouter.daemonVersion)\n" +
    "  control: \(options.socketPath)\n" +
    "  runtime: 127.0.0.1:\(options.runtimePort)\n",
    stderr
)

do {
    try server.run()
} catch {
    fputs("injectiond: \(error)\n", stderr)
    exit(1)
}
