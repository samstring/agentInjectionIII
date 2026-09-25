import SwiftUI
import AppKit
import AgentInjectionCore

@main
struct AgentInjectionMenuApp: App {
    @StateObject private var model =
        MenuStatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
                .frame(minWidth: 340)
                .task {
                    model.start()
                }
        } label: {
            Image(systemName: model.symbolName)
                .help(model.statusTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MenuStatusModel: ObservableObject {
    @Published private(set) var diagnostics:
        DiagnosticsResult?
    @Published private(set) var connectionError:
        String?
    @Published private(set) var lastUpdated:
        Date?

    private let socketPath: String
    private let worker = DispatchQueue(
        label: "agentInjectionIII.menu.status",
        qos: .utility
    )
    private var timer: Timer?
    private var started = false

    init(
        socketPath: String =
            ProcessInfo.processInfo.environment[
                "AGENT_INJECTION_SOCKET"
            ] ?? "/tmp/agentInjectionIII.sock"
    ) {
        self.socketPath = socketPath
    }

    var statusTitle: String {
        guard connectionError == nil,
              let diagnostics else {
            return "Agent Injection Offline"
        }

        if diagnostics.status.ready {
            return "Agent Injection Ready"
        }

        if diagnostics.lastError.error != nil {
            return "Agent Injection Issue"
        }

        return "Agent Injection Listening"
    }

    var symbolName: String {
        guard connectionError == nil,
              let diagnostics else {
            return "circle"
        }

        if diagnostics.lastError.error != nil {
            return "exclamationmark.circle.fill"
        }

        if diagnostics.status.ready {
            return "bolt.circle.fill"
        }

        return "circle.dotted"
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
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
                    self?.connectionError = nil
                    self?.lastUpdated = Date()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.diagnostics = nil
                    self?.connectionError =
                        String(describing: error)
                    self?.lastUpdated = Date()
                }
            }
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
                    model.refresh()
                } label: {
                    Image(
                        systemName: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderless)
            }

            if let error = model.connectionError {
                Label(
                    "injectiond unavailable",
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

                Button("Quit") {
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
