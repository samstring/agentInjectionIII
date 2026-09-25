import Foundation
import Darwin
import AgentInjectionCore

struct DaemonOptions {
    var socketPath = "/tmp/agentInjectionIII.sock"
    var projectRoot: String?
    var runtimePort: UInt16 = 8887
    var tracePort: UInt16 = 8888
    var derivedDataRoot: String?
    var enableDevices = false
    var codeSigningIdentity: String?
    var xcodePath: String?
    var deviceTesting = false
    var deviceLibraries: [String] = [
        "-framework", "XCTest",
        "-lXCTestSwiftSupport"
    ]
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

        case "--trace-port":
            guard index + 1 < arguments.count,
                  let port = UInt16(arguments[index + 1]),
                  port > 0 else {
                fatalUsage("--trace-port requires a valid TCP port")
            }
            options.tracePort = port
            index += 2

        case "--enable-devices":
            options.enableDevices = true
            index += 1

        case "--codesign-identity":
            guard index + 1 < arguments.count else {
                fatalUsage("--codesign-identity requires a value")
            }
            options.codeSigningIdentity = arguments[index + 1]
            index += 2

        case "--xcode-path":
            guard index + 1 < arguments.count else {
                fatalUsage("--xcode-path requires an Xcode.app path")
            }
            options.xcodePath = arguments[index + 1]
            index += 2

        case "--device-testing":
            options.deviceTesting = true
            index += 1

        case "--device-libraries":
            guard index + 1 < arguments.count else {
                fatalUsage("--device-libraries requires a quoted linker option string")
            }
            options.deviceLibraries = arguments[index + 1]
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            index += 2

        case "--derived-data":
            guard index + 1 < arguments.count else {
                fatalUsage("--derived-data requires a path")
            }
            options.derivedDataRoot = arguments[index + 1]
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
    usage: injectiond [--socket PATH] [--project ROOT] [--runtime-port PORT] [--trace-port PORT] [--derived-data PATH] [--xcode-path XCODE.app] [--enable-devices] [--codesign-identity IDENTITY] [--device-testing] [--device-libraries OPTIONS]

      --socket PATH       Unix domain socket path for injectionctl.
                          Default: /tmp/agentInjectionIII.sock
      --project ROOT      Project root used to resolve relative source paths.
      --runtime-port PORT InjectionNext client runtime TCP port.
                          Default: 8887
      --trace-port PORT   AgentTraceBridge TCP port.
                          Default: 8888
      --derived-data PATH Override Xcode DerivedData root used for build-log discovery.
      --xcode-path PATH   Xcode.app to use instead of xcode-select.
      --enable-devices    Listen on all interfaces for device injection and trace.
      --codesign-identity IDENTITY
                          Expanded Apple code signing identity used for physical-device dylibs.
      --device-testing    Link XCTest/Swift Testing support into device injection dylibs.
      --device-libraries OPTIONS
                          Quoted linker options for device tests.
                          Default: -framework XCTest -lXCTestSwiftSupport
    """)
}

private func fatalUsage(_ message: String) -> Never {
    fputs("injectiond: \(message)\n", stderr)
    printUsage()
    exit(2)
}

let options = parseOptions()
let logStore = AgentLogStore()
let runtimeServer = InjectionNextRuntimeServer(
    port: options.runtimePort,
    devicesEnabled: options.enableDevices,
    logStore: logStore,
    xcodePath: options.xcodePath
)

do {
    try runtimeServer.start()
} catch {
    fputs("injectiond: unable to start InjectionNext runtime server: \(error)\n", stderr)
    exit(1)
}

let traceServer = AgentTraceServer(
    port: options.tracePort,
    devicesEnabled: options.enableDevices,
    logStore: logStore
)

do {
    try traceServer.start()
} catch {
    fputs("injectiond: unable to start Agent trace server: \(error)\n", stderr)
    exit(1)
}

let backend = InjectionNextRuntimeBackend(
    runtimeServer: runtimeServer,
    traceServer: traceServer,
    projectRoot: options.projectRoot,
    derivedDataRoot: options.derivedDataRoot,
    codeSigningIdentity: options.codeSigningIdentity,
    xcodePath: options.xcodePath,
    deviceTesting: options.deviceTesting,
    deviceLibraries: options.deviceLibraries
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
    "  runtime: \(options.enableDevices ? "0.0.0.0" : "127.0.0.1"):\(options.runtimePort)\n" +
    "  trace:   \(options.enableDevices ? "0.0.0.0" : "127.0.0.1"):\(options.tracePort)\n",
    stderr
)

do {
    try server.run()
} catch {
    fputs("injectiond: \(error)\n", stderr)
    exit(1)
}
