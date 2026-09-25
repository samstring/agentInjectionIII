import SwiftUI
import AppKit
import AgentInjectionCore

@main
struct AgentInjectionIIIApp: App {
    @StateObject private var model =
        MenuStatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
                .frame(minWidth: 360)
                .task {
                    model.refreshDiagnostics()
                }
        } label: {
            Image(systemName: model.symbolName)
                .help(model.statusTitle)
                .task {
                    model.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MenuStatusModel: ObservableObject {
    @Published private(set) var diagnostics:
        DiagnosticsResult?
    @Published private(set) var daemonStatus:
        DaemonStatus?
    @Published private(set) var connectionError:
        String?
    @Published private(set) var lastUpdated:
        Date?

    private let socketPath: String
    private let worker = DispatchQueue(
        label: "AgentInjectionIII.menu.status",
        qos: .utility
    )
    private let daemonController: DaemonController
    private var timer: Timer?
    private var started = false
    private var terminateObserver: NSObjectProtocol?

    init(
        socketPath: String =
            ProcessInfo.processInfo.environment[
                "AGENT_INJECTION_SOCKET"
            ] ?? "/tmp/agentInjectionIII.sock"
    ) {
        self.socketPath = socketPath
        self.daemonController =
            DaemonController(socketPath: socketPath)
    }

    var statusTitle: String {
        guard connectionError == nil,
              let daemonStatus else {
            return "AgentInjectionIII Offline"
        }

        if diagnostics?.lastError.error != nil {
            return "AgentInjectionIII Issue"
        }

        return daemonStatus.backend.ready
            ? "AgentInjectionIII Ready"
            : "AgentInjectionIII Listening"
    }

    var symbolName: String {
        guard connectionError == nil,
              let daemonStatus else {
            return "circle"
        }

        if diagnostics?.lastError.error != nil {
            return "exclamationmark.circle.fill"
        }

        return daemonStatus.backend.ready
            ? "bolt.circle.fill"
            : "circle.dotted"
    }

    func start() {
        guard !started else { return }
        started = true

        daemonController.ensureRunning()
        refreshStatus()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.75
        ) { [weak self] in
            self?.refreshStatus()
        }

        timer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        terminateObserver =
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.shutdown()
            }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil

        if let terminateObserver {
            NotificationCenter.default.removeObserver(
                terminateObserver
            )
            self.terminateObserver = nil
        }

        daemonController.stopOwnedDaemon()
    }

    func refreshStatus() {
        let socketPath = socketPath

        worker.async { [weak self] in
            do {
                let response = try UnixSocketClient(
                    socketPath: socketPath
                ).send(
                    ControlRequest(
                        action: .status
                    )
                )

                guard let status =
                        response.status else {
                    throw MenuStatusError(
                        message:
                            response.error?.message
                            ?? "Daemon returned no status payload."
                    )
                }

                DispatchQueue.main.async {
                    self?.daemonStatus = status
                    self?.connectionError = nil
                    self?.lastUpdated = Date()
                }
            } catch {
                self?.daemonController.ensureRunning()

                DispatchQueue.main.async {
                    self?.daemonStatus = nil
                    self?.connectionError =
                        String(describing: error)
                    self?.lastUpdated = Date()
                }
            }
        }
    }

    func refreshDiagnostics() {
        let socketPath = socketPath

        worker.async { [weak self] in
            do {
                let response = try UnixSocketClient(
                    socketPath: socketPath
                ).send(
                    ControlRequest(
                        action: .diagnostics,
                        limit: 100
                    )
                )

                guard let diagnostics =
                        response.diagnostics else {
                    throw MenuStatusError(
                        message:
                            response.error?.message
                            ?? "Daemon returned no diagnostics payload."
                    )
                }

                DispatchQueue.main.async {
                    self?.diagnostics = diagnostics
                    self?.daemonStatus =
                        diagnostics.status
                    self?.connectionError = nil
                    self?.lastUpdated = Date()
                }
            } catch {
                self?.daemonController.ensureRunning()

                DispatchQueue.main.async {
                    self?.connectionError =
                        String(describing: error)
                    self?.lastUpdated = Date()
                }
            }
        }
    }
}

private final class DaemonController {
    private let socketPath: String
    private let queue = DispatchQueue(
        label: "AgentInjectionIII.daemon.lifecycle",
        qos: .utility
    )

    private var ownedProcess: Process?
    private var logHandle: FileHandle?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func ensureRunning() {
        queue.async { [weak self] in
            guard let self else { return }

            if self.daemonResponds() {
                return
            }

            if let process = self.ownedProcess,
               process.isRunning {
                return
            }

            self.launchDaemon()
        }
    }

    func stopOwnedDaemon() {
        queue.sync {
            if let process = ownedProcess,
               process.isRunning {
                process.terminate()
            }

            ownedProcess = nil
            try? logHandle?.close()
            logHandle = nil
        }
    }

    private func daemonResponds() -> Bool {
        do {
            let response = try UnixSocketClient(
                socketPath: socketPath
            ).send(
                ControlRequest(action: .status)
            )
            return response.status != nil
        } catch {
            return false
        }
    }

    private func launchDaemon() {
        guard let daemonURL = resolveDaemonURL() else {
            return
        }

        if FileManager.default.fileExists(
            atPath: socketPath
        ) {
            try? FileManager.default.removeItem(
                atPath: socketPath
            )
        }

        let process = Process()
        process.executableURL = daemonURL

        var arguments = [
            "--socket", socketPath,
            "--enable-devices"
        ]

        let environment =
            ProcessInfo.processInfo.environment

        if let projectRoot =
            environment[
                "AGENT_INJECTION_PROJECT_ROOT"
            ],
           !projectRoot.isEmpty {
            arguments += [
                "--project", projectRoot
            ]
        }

        if let derivedData =
            environment[
                "AGENT_INJECTION_DERIVED_DATA"
            ],
           !derivedData.isEmpty {
            arguments += [
                "--derived-data", derivedData
            ]
        }

        if let xcodePath =
            environment[
                "AGENT_INJECTION_XCODE_PATH"
            ],
           !xcodePath.isEmpty {
            arguments += [
                "--xcode-path", xcodePath
            ]
        }

        process.arguments = arguments
        process.environment = environment

        if let handle = openLogHandle() {
            process.standardOutput = handle
            process.standardError = handle
            logHandle = handle
        }

        process.terminationHandler = {
            [weak self, weak process] _ in
            guard let self,
                  let process else {
                return
            }

            self.queue.async {
                if self.ownedProcess === process {
                    self.ownedProcess = nil
                    try? self.logHandle?.close()
                    self.logHandle = nil
                }
            }
        }

        do {
            try process.run()
            ownedProcess = process
        } catch {
            try? logHandle?.close()
            logHandle = nil
            ownedProcess = nil
        }
    }

    private func resolveDaemonURL() -> URL? {
        let fileManager = FileManager.default
        let environment =
            ProcessInfo.processInfo.environment

        if let override =
            environment["AGENT_INJECTION_DAEMON"],
           fileManager.isExecutableFile(
                atPath: override
           ) {
            return URL(fileURLWithPath: override)
        }

        let bundled =
            Bundle.main.bundleURL
                .appendingPathComponent(
                    "Contents/Helpers/injectiond"
                )
        if fileManager.isExecutableFile(
            atPath: bundled.path
        ) {
            return bundled
        }

        if let executable =
            Bundle.main.executableURL {
            let sibling =
                executable
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "injectiond"
                    )
            if fileManager.isExecutableFile(
                atPath: sibling.path
            ) {
                return sibling
            }
        }

        let commandPath =
            URL(fileURLWithPath:
                CommandLine.arguments[0]
            )
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("injectiond")
        if fileManager.isExecutableFile(
            atPath: commandPath.path
        ) {
            return commandPath
        }

        if let path = environment["PATH"] {
            for directory in
                path.split(separator: ":") {
                let candidate =
                    URL(
                        fileURLWithPath:
                            String(directory)
                    )
                    .appendingPathComponent(
                        "injectiond"
                    )
                if fileManager.isExecutableFile(
                    atPath: candidate.path
                ) {
                    return candidate
                }
            }
        }

        return nil
    }

    private func openLogHandle() -> FileHandle? {
        let fileManager = FileManager.default
        let logs =
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Logs/AgentInjectionIII",
                    isDirectory: true
                )

        do {
            try fileManager.createDirectory(
                at: logs,
                withIntermediateDirectories: true
            )

            let file =
                logs.appendingPathComponent(
                    "injectiond.log"
                )

            if !fileManager.fileExists(
                atPath: file.path
            ) {
                fileManager.createFile(
                    atPath: file.path,
                    contents: nil
                )
            }

            let handle =
                try FileHandle(
                    forWritingTo: file
                )
            try handle.seekToEnd()
            return handle
        } catch {
            return nil
        }
    }
}

private struct MenuStatusError:
    Error,
    CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

private struct StatusMenuView: View {
    @ObservedObject var model: MenuStatusModel

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            HStack {
                Image(
                    systemName: model.symbolName
                )
                Text(model.statusTitle)
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshDiagnostics()
                } label: {
                    Image(
                        systemName: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderless)
            }

            if let error = model.connectionError {
                Label(
                    "injectiond is starting or unavailable",
                    systemImage:
                        "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)

                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let diagnostics =
                        model.diagnostics {
                Divider()

                statusSection(diagnostics)
                targetsSection(diagnostics)

                Divider()

                HStack {
                    Label(
                        diagnostics.trace.connected
                            ? "Trace bridge connected"
                            : "Trace bridge disconnected",
                        systemImage:
                            diagnostics.trace.connected
                            ? "waveform.path"
                            : "waveform.path.badge.minus"
                    )
                    Spacer()
                    if diagnostics.trace.active {
                        Text("ACTIVE")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error =
                    diagnostics.lastError.error {
                    Divider()
                    Label(
                        error.code,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)

                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                let noteworthy =
                    diagnostics.logs.entries
                        .filter {
                            $0.level != "info"
                        }
                        .suffix(5)

                if !noteworthy.isEmpty {
                    Divider()
                    Text("Recent diagnostics")
                        .font(.subheadline)
                        .bold()

                    ForEach(
                        Array(noteworthy.enumerated()),
                        id: \.offset
                    ) { _, entry in
                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            Text(
                                entry.level.uppercased()
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Divider()

            HStack {
                if let updated =
                    model.lastUpdated {
                    Text(
                        "Updated " +
                        updated.formatted(
                            date: .omitted,
                            time: .standard
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Quit AgentInjectionIII") {
                    model.shutdown()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func statusSection(
        _ diagnostics: DiagnosticsResult
    ) -> some View {
        HStack {
            Text("Injection")
            Spacer()
            Text(
                diagnostics.status.ready
                    ? "Ready"
                    : "Listening"
            )
            .foregroundStyle(.secondary)
        }

        HStack {
            Text("Doctor")
            Spacer()
            Text(
                diagnostics.doctor.ready
                    ? "Pass"
                    : "Needs attention"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func targetsSection(
        _ diagnostics: DiagnosticsResult
    ) -> some View {
        let targets =
            diagnostics.targets.targets

        HStack {
            Text("Connected targets")
            Spacer()
            Text("\(targets.count)")
                .foregroundStyle(.secondary)
        }

        if targets.isEmpty {
            Text("No runtime target connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(targets, id: \.id) {
                target in
                VStack(
                    alignment: .leading,
                    spacing: 2
                ) {
                    HStack {
                        Image(
                            systemName:
                                target.isLocal
                                ? "desktopcomputer"
                                : "iphone"
                        )
                        Text(
                            target.platform
                            ?? "Unknown platform"
                        )
                        Spacer()
                        Text(
                            target.arch
                            ?? ""
                        )
                        .foregroundStyle(.secondary)
                    }

                    if let peer =
                        target.peerAddress {
                        Text(peer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
