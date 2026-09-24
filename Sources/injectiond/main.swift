import Foundation
import Darwin
import AgentInjectionCore

private struct DaemonOptions {
    var socketPath = "/tmp/agentInjectionIII.sock"
    var projectRoot: String?
}

private func parseOptions() -> DaemonOptions {
    var options = DaemonOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
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
    usage: injectiond [--socket PATH] [--project ROOT]

      --socket PATH   Unix domain socket path.
                      Default: /tmp/agentInjectionIII.sock
      --project ROOT  Project root used to resolve relative source paths.
    """)
}

private func fatalUsage(_ message: String) -> Never {
    fputs("injectiond: \(message)\n", stderr)
    printUsage()
    exit(2)
}

let options = parseOptions()
let backend = ScaffoldInjectionBackend(projectRoot: options.projectRoot)
let router = ControlRouter(
    socketPath: options.socketPath,
    backend: backend
)
let server = UnixSocketServer(
    socketPath: options.socketPath,
    handler: router.handle
)

fputs(
    "agentInjectionIII injectiond \(ControlRouter.daemonVersion) listening at " +
    "\(options.socketPath)\n",
    stderr
)

do {
    try server.run()
} catch {
    fputs("injectiond: \(error)\n", stderr)
    exit(1)
}
