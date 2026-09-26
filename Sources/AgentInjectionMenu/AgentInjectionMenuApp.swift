import SwiftUI
import AppKit
import Carbon
import AgentInjectionCore

@main
struct AgentInjectionIIIApp: App {
    @StateObject private var model =
        MenuStatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
                .frame(minWidth: 460)
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
    @Published private(set) var pendingChanges:
        PendingChangesResult?
    @Published private(set) var projects:
        ProjectsResult?
    @Published private(set) var runtimeTargets:
        TargetsResult?
    @Published private(set) var pendingByProject:
        [String: PendingChangesResult] = [:]
    @Published private(set) var manualInjectionError:
        String?
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
    private var persistedProjectRoots: [String]
    private var timer: Timer?
    private var hotKey: GlobalHotKey?
    private var started = false
    private var terminateObserver: NSObjectProtocol?

    private static let projectRootsDefaultsKey =
        "AgentInjectionIII.projectRoots"
    private static let legacyProjectRootDefaultsKey =
        "AgentInjectionIII.projectRoot"

    init(
        socketPath: String =
            ProcessInfo.processInfo.environment[
                "AGENT_INJECTION_SOCKET"
            ] ?? "/tmp/agentInjectionIII.sock"
    ) {
        let environment =
            ProcessInfo.processInfo.environment
        var roots =
            UserDefaults.standard.stringArray(
                forKey:
                    Self.projectRootsDefaultsKey
            ) ?? []

        if let environmentRoot =
            environment[
                "AGENT_INJECTION_PROJECT_ROOT"
            ].flatMap({
                $0.isEmpty ? nil : $0
            }) {
            roots.append(environmentRoot)
        }

        if roots.isEmpty,
           let legacy =
            UserDefaults.standard.string(
                forKey:
                    Self.legacyProjectRootDefaultsKey
            ),
           !legacy.isEmpty {
            roots.append(legacy)
        }

        roots = Self.normalizedRoots(roots)

        self.socketPath = socketPath
        self.persistedProjectRoots = roots
        self.daemonController =
            DaemonController(
                socketPath: socketPath,
                projectRoots: roots
            )
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

    var totalPendingCount: Int {
        if !pendingByProject.isEmpty {
            return pendingByProject.values
                .reduce(0) {
                    $0 + $1.files.count
                }
        }
        return pendingChanges?.files.count ?? 0
    }

    func start() {
        guard !started else { return }
        started = true

        daemonController.ensureRunning()

        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_Minus),
            modifiers: UInt32(controlKey)
        ) { [weak self] in
            Task { @MainActor in
                self?.injectPendingChanges()
            }
        }

        refreshStatus()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.75
        ) { [weak self] in
            self?.registerPersistedProjects()
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
                forName:
                    NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.shutdown()
                }
            }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        hotKey = nil

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
        let daemonController = daemonController
        daemonController.refreshCodeSigningIdentity()

        worker.async { [weak self] in
            do {
                let client = UnixSocketClient(
                    socketPath: socketPath
                )
                let statusResponse = try client.send(
                    ControlRequest(
                        action: .status
                    )
                )
                let projectsResponse = try client.send(
                    ControlRequest(
                        action: .projects
                    )
                )
                let pendingResponse = try client.send(
                    ControlRequest(
                        action: .pendingChanges
                    )
                )
                let targetsResponse = try client.send(
                    ControlRequest(
                        action: .targets
                    )
                )

                guard let status =
                        statusResponse.status else {
                    throw MenuStatusError(
                        message:
                            statusResponse.error?.message
                            ?? "Daemon returned no status payload."
                    )
                }

                guard let projects =
                        projectsResponse.projects else {
                    throw MenuStatusError(
                        message:
                            projectsResponse.error?.message
                            ?? "Daemon returned no projects payload."
                    )
                }

                var pendingByProject:
                    [String: PendingChangesResult] = [:]

                for project in projects.projects {
                    let response = try client.send(
                        ControlRequest(
                            action: .pendingChanges,
                            projectID: project.id
                        )
                    )
                    if let pending =
                        response.pendingChanges {
                        pendingByProject[
                            project.id
                        ] = pending
                    }
                }

                DispatchQueue.main.async {
                    self?.daemonStatus = status
                    self?.projects = projects
                    self?.runtimeTargets =
                        targetsResponse.targets
                    self?.pendingChanges =
                        pendingResponse.pendingChanges
                    self?.pendingByProject =
                        pendingByProject
                    self?.connectionError = nil
                    self?.lastUpdated = Date()
                }
            } catch {
                daemonController.ensureRunning()

                DispatchQueue.main.async {
                    self?.daemonStatus = nil
                    self?.projects = nil
                    self?.runtimeTargets = nil
                    self?.pendingChanges = nil
                    self?.pendingByProject = [:]
                    self?.connectionError =
                        String(describing: error)
                    self?.lastUpdated = Date()
                }
            }
        }
    }

    func injectPendingChanges(
        projectID: String? = nil,
        target: String? = nil
    ) {
        let socketPath = socketPath

        worker.async { [weak self] in
            do {
                let response = try UnixSocketClient(
                    socketPath: socketPath
                ).send(
                    ControlRequest(
                        action: .injectPending,
                        target: target,
                        projectID: projectID
                    )
                )

                DispatchQueue.main.async {
                    self?.manualInjectionError =
                        response.ok
                        ? nil
                        : response.error?.message
                    self?.refreshStatus()
                    self?.refreshDiagnostics()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.manualInjectionError =
                        String(describing: error)
                }
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.prompt = "Add Project"
        panel.message =
            "Choose one or more independent project directories for AgentInjectionIII to watch."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        if let first = persistedProjectRoots.first {
            panel.directoryURL =
                URL(fileURLWithPath: first)
        }

        guard panel.runModal() == .OK,
              !panel.urls.isEmpty else {
            return
        }

        for url in panel.urls {
            addProject(
                url.standardizedFileURL.path
            )
        }
    }

    func removeProject(
        id: String,
        root: String
    ) {
        let socketPath = socketPath

        worker.async { [weak self] in
            do {
                let response = try UnixSocketClient(
                    socketPath: socketPath
                ).send(
                    ControlRequest(
                        action: .projectRemove,
                        projectID: id
                    )
                )

                guard response.ok else {
                    throw MenuStatusError(
                        message:
                            response.error?.message
                            ?? "Unable to remove project."
                    )
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.persistedProjectRoots.removeAll {
                        Self.standardizedRoot($0) ==
                        Self.standardizedRoot(root)
                    }
                    self.persistProjectRoots()
                    self.daemonController
                        .updateProjectRoots(
                            self.persistedProjectRoots
                        )
                    self.refreshStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.manualInjectionError =
                        String(describing: error)
                }
            }
        }
    }

    func pending(
        for projectID: String
    ) -> PendingChangesResult? {
        pendingByProject[projectID]
    }

    func targets(
        for project: ProjectSessionSummary
    ) -> [RuntimeTarget] {
        let ids = Set(project.targetIDs)
        return runtimeTargets?.targets
            .filter {
                ids.contains($0.id)
            } ?? []
    }

    func refreshDiagnostics() {
        let socketPath = socketPath
        let daemonController = daemonController

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
                daemonController.ensureRunning()

                DispatchQueue.main.async {
                    self?.connectionError =
                        String(describing: error)
                    self?.lastUpdated = Date()
                }
            }
        }
    }

    private func addProject(
        _ root: String
    ) {
        let normalized =
            Self.standardizedRoot(root)

        if !persistedProjectRoots.contains(
            normalized
        ) {
            persistedProjectRoots.append(
                normalized
            )
            persistProjectRoots()
            daemonController.updateProjectRoots(
                persistedProjectRoots
            )
        }

        let socketPath = socketPath
        worker.async { [weak self] in
            do {
                let response = try UnixSocketClient(
                    socketPath: socketPath
                ).send(
                    ControlRequest(
                        action: .projectAdd,
                        path: normalized
                    )
                )

                DispatchQueue.main.async {
                    self?.manualInjectionError =
                        response.ok
                        ? nil
                        : response.error?.message
                    self?.refreshStatus()
                    self?.refreshDiagnostics()
                }
            } catch {
                daemonController.ensureRunning()
                DispatchQueue.main.async {
                    self?.manualInjectionError =
                        String(describing: error)
                }
            }
        }
    }

    private func registerPersistedProjects() {
        let roots = persistedProjectRoots
        guard !roots.isEmpty else {
            return
        }

        let socketPath = socketPath
        worker.async { [weak self] in
            do {
                let client = UnixSocketClient(
                    socketPath: socketPath
                )
                for root in roots {
                    _ = try client.send(
                        ControlRequest(
                            action: .projectAdd,
                            path: root
                        )
                    )
                }
                DispatchQueue.main.async {
                    self?.refreshStatus()
                }
            } catch {
                daemonController.ensureRunning()
            }
        }
    }

    private func persistProjectRoots() {
        UserDefaults.standard.set(
            persistedProjectRoots,
            forKey:
                Self.projectRootsDefaultsKey
        )
        UserDefaults.standard.removeObject(
            forKey:
                Self.legacyProjectRootDefaultsKey
        )
    }

    private static func normalizedRoots(
        _ roots: [String]
    ) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for root in roots {
            let value = standardizedRoot(root)
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }

    private static func standardizedRoot(
        _ root: String
    ) -> String {
        URL(
            fileURLWithPath:
                NSString(
                    string: root
                ).expandingTildeInPath
        )
        .standardizedFileURL
        .path
    }
}

private final class DaemonController:
    @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(
        label: "AgentInjectionIII.daemon.lifecycle",
        qos: .utility
    )

    private var ownedProcess: Process?
    private var logHandle: FileHandle?
    private var projectRoots: [String]
    private var ownedCodeSignIdentity: String?

    private static let signingDefaultsDomain =
        "com.agentInjectionIII"

    init(
        socketPath: String,
        projectRoots: [String]
    ) {
        self.socketPath = socketPath
        self.projectRoots = projectRoots
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

    func updateProjectRoots(
        _ projectRoots: [String]
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            self.projectRoots =
                projectRoots.map {
                    URL(
                        fileURLWithPath: $0
                    )
                    .standardizedFileURL
                    .path
                }

            if !self.daemonResponds(),
               self.ownedProcess?.isRunning != true {
                self.launchDaemon()
            }
        }
    }

    func refreshCodeSigningIdentity() {
        queue.async { [weak self] in
            guard let self,
                  let process = self.ownedProcess,
                  process.isRunning else {
                return
            }

            let identity =
                self.resolveCodeSignIdentity()
            guard identity !=
                    self.ownedCodeSignIdentity else {
                return
            }

            process.terminate()
            process.waitUntilExit()
            guard self.ownedProcess === process else {
                return
            }

            self.ownedProcess = nil
            self.ownedCodeSignIdentity = nil
            try? self.logHandle?.close()
            self.logHandle = nil
            self.removeStaleSocket()
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
            ownedCodeSignIdentity = nil
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
        guard let daemonURL =
                resolveDaemonURL() else {
            return
        }

        removeStaleSocket()

        let process = Process()
        process.executableURL = daemonURL

        var arguments = [
            "--socket", socketPath,
            "--enable-devices"
        ]

        let codeSignIdentity =
            resolveCodeSignIdentity()
        if let codeSignIdentity {
            arguments += [
                "--codesign-identity",
                codeSignIdentity
            ]
        }

        let environment =
            ProcessInfo.processInfo.environment

        var roots = projectRoots
        if let environmentProject =
            environment[
                "AGENT_INJECTION_PROJECT_ROOT"
            ].flatMap({
                $0.isEmpty ? nil : $0
            }) {
            roots.append(environmentProject)
        }

        var seenRoots = Set<String>()
        for root in roots {
            let normalized = URL(
                fileURLWithPath:
                    NSString(
                        string: root
                    ).expandingTildeInPath
            )
            .standardizedFileURL
            .path
            guard seenRoots.insert(
                normalized
            ).inserted else {
                continue
            }
            arguments += [
                "--project", normalized
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
                    self.ownedCodeSignIdentity = nil
                    try? self.logHandle?.close()
                    self.logHandle = nil
                }
            }
        }

        do {
            try process.run()
            ownedProcess = process
            ownedCodeSignIdentity =
                codeSignIdentity
        } catch {
            try? logHandle?.close()
            logHandle = nil
            ownedProcess = nil
            ownedCodeSignIdentity = nil
        }
    }

    private func resolveCodeSignIdentity()
        -> String? {
        var identities = Set<String>()

        for root in projectRoots {
            let rootURL = URL(
                fileURLWithPath: root
            ).standardizedFileURL

            let projectFiles =
                (try? FileManager.default
                    .contentsOfDirectory(
                        at: rootURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ))?.filter {
                        $0.pathExtension ==
                            "xcodeproj"
                    } ?? []

            guard projectFiles.count == 1,
                  let rawIdentity =
                    UserDefaults(
                        suiteName:
                            Self.signingDefaultsDomain
                    )?.string(
                        forKey:
                            projectFiles[0]
                                .standardizedFileURL
                                .path
                    ) else {
                continue
            }

            let identity =
                rawIdentity.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            if !identity.isEmpty,
               identity != "-" {
                identities.insert(identity)
            }
        }

        return identities.count == 1
            ? identities.first
            : nil
    }

    private func removeStaleSocket() {
        guard FileManager.default
            .fileExists(
                atPath: socketPath
            ) else {
            return
        }

        try? FileManager.default.removeItem(
            atPath: socketPath
        )
    }

    private func resolveDaemonURL() -> URL? {
        let fileManager = FileManager.default
        let environment =
            ProcessInfo.processInfo.environment

        if let override =
            environment[
                "AGENT_INJECTION_DAEMON"
            ],
           fileManager.isExecutableFile(
                atPath: override
           ) {
            return URL(
                fileURLWithPath: override
            )
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
            URL(
                fileURLWithPath:
                    CommandLine.arguments[0]
            )
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "injectiond"
            )
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

    private func openLogHandle()
        -> FileHandle? {
        let fileManager = FileManager.default
        let logs =
            fileManager
                .homeDirectoryForCurrentUser
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

private final class GlobalHotKey {
    private var hotKeyRef:
        EventHotKeyRef?
    private var handlerRef:
        EventHandlerRef?
    private let action: () -> Void

    init?(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass:
                OSType(kEventClassKeyboard),
            eventKind:
                UInt32(kEventHotKeyPressed)
        )

        let installStatus =
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else {
                        return noErr
                    }

                    let hotKey =
                        Unmanaged<GlobalHotKey>
                            .fromOpaque(
                                userData
                            )
                            .takeUnretainedValue()
                    hotKey.action()
                    return noErr
                },
                1,
                &eventType,
                Unmanaged
                    .passUnretained(self)
                    .toOpaque(),
                &handlerRef
            )

        guard installStatus == noErr else {
            return nil
        }

        var identifier = EventHotKeyID(
            signature:
                OSType(0x4147494E),
            id: 1
        )

        let registerStatus =
            RegisterEventHotKey(
                keyCode,
                modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

        guard registerStatus == noErr else {
            if let handlerRef {
                RemoveEventHandler(
                    handlerRef
                )
            }
            self.handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(
                hotKeyRef
            )
        }
        if let handlerRef {
            RemoveEventHandler(
                handlerRef
            )
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
                    model.refreshStatus()
                    model.refreshDiagnostics()
                } label: {
                    Image(
                        systemName:
                            "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderless)
            }

            Divider()

            projectsSection

            if model.totalPendingCount > 0 {
                Divider()

                Button(
                    "Inject All Changed Files"
                ) {
                    model.injectPendingChanges()
                }
                .keyboardShortcut(
                    "-",
                    modifiers: [.control]
                )

                Text(
                    "Control + - routes every pending source to its owning project and all matching runtime devices."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let error =
                model.manualInjectionError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let error =
                model.connectionError {
                Divider()
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
                        .suffix(4)

                if !noteworthy.isEmpty {
                    Divider()
                    Text("Recent diagnostics")
                        .font(.subheadline)
                        .bold()

                    ForEach(
                        Array(
                            noteworthy.enumerated()
                        ),
                        id: \.offset
                    ) { _, entry in
                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            Text(
                                entry.level
                                    .uppercased()
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

                Button(
                    "Quit AgentInjectionIII"
                ) {
                    model.shutdown()
                    NSApplication.shared
                        .terminate(nil)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var projectsSection: some View {
        HStack {
            Text("Projects")
                .font(.subheadline)
                .bold()
            Spacer()

            if let projects = model.projects {
                Text(
                    "\(projects.projects.count)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                model.chooseProject()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add independent project directory")
        }

        let projects =
            model.projects?.projects ?? []

        if projects.isEmpty {
            Text(
                "No project directories registered."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Add Project…") {
                model.chooseProject()
            }
        } else {
            ForEach(
                projects,
                id: \.id
            ) { project in
                projectSection(project)
            }
        }

        if let unmatched =
            model.projects?.unmatchedTargets,
           !unmatched.isEmpty {
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Label(
                    "Unmatched Runtime Sessions",
                    systemImage:
                        "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(
                    unmatched,
                    id: \.id
                ) { target in
                    runtimeRow(target)
                }
            }
        }
    }

    @ViewBuilder
    private func projectSection(
        _ project: ProjectSessionSummary
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            HStack {
                Image(
                    systemName: "folder"
                )
                Text(project.displayName)
                    .font(.subheadline)
                    .bold()

                Spacer()

                if project.pendingCount > 0 {
                    Text(
                        "\(project.pendingCount) changed"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button {
                    model.removeProject(
                        id: project.id,
                        root: project.root
                    )
                } label: {
                    Image(
                        systemName: "minus.circle"
                    )
                }
                .buttonStyle(.borderless)
                .help("Remove project")
            }

            Text(project.root)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)

            let targets =
                model.targets(for: project)

            if targets.isEmpty {
                Label(
                    "No matching runtime",
                    systemImage:
                        "iphone.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(
                    targets,
                    id: \.id
                ) { target in
                    runtimeRow(target)
                }
            }

            if let pending =
                model.pending(for: project.id),
               !pending.files.isEmpty {
                ForEach(
                    Array(
                        pending.files.suffix(3)
                    ),
                    id: \.self
                ) { file in
                    HStack {
                        Image(
                            systemName: "doc"
                        )
                        .foregroundStyle(.secondary)

                        Text(
                            URL(
                                fileURLWithPath:
                                    file
                            )
                            .lastPathComponent
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Button(
                    targets.count > 1
                        ? "Inject → \(targets.count) Devices"
                        : "Inject Changed Files"
                ) {
                    model.injectPendingChanges(
                        projectID: project.id
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func runtimeRow(
        _ target: RuntimeTarget
    ) -> some View {
        HStack(spacing: 6) {
            Image(
                systemName:
                    target.isLocal
                    ? "desktopcomputer"
                    : "iphone"
            )
            .foregroundStyle(
                target.connected
                    ? Color.primary
                    : Color.secondary
            )

            VStack(
                alignment: .leading,
                spacing: 1
            ) {
                Text(
                    target.executable
                        .map {
                            URL(
                                fileURLWithPath: $0
                            )
                            .lastPathComponent
                        }
                    ?? target.platform
                    ?? "Runtime"
                )
                .font(.caption)

                Text(
                    [
                        target.peerAddress,
                        target.platform,
                        target.arch
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .frame(
                    width: 7,
                    height: 7
                )
                .foregroundStyle(
                    target.connected
                        ? Color.green
                        : Color.secondary
                )
        }
        .padding(.leading, 18)
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

        HStack {
            Text("Connected runtimes")
            Spacer()
            Text(
                "\(diagnostics.targets.targets.count)"
            )
            .foregroundStyle(.secondary)
        }
    }
}
