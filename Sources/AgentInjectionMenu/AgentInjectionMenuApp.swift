import SwiftUI
import AppKit
import Carbon
import AgentInjectionCore

private enum MenuLanguage {
    case zhHans
    case en

    static var current: MenuLanguage {
        let environment =
            ProcessInfo.processInfo.environment
        let configured =
            environment[
                "AGENT_INJECTION_LANGUAGE"
            ] ??
            UserDefaults.standard.string(
                forKey:
                    "AgentInjectionIII.language"
            )

        if let configured {
            let normalized =
                configured.lowercased()
            if normalized.hasPrefix("en") {
                return .en
            }
            if normalized.hasPrefix("zh") {
                return .zhHans
            }
        }

        // Product default is Simplified Chinese. English can be selected
        // with AGENT_INJECTION_LANGUAGE=en or the UserDefaults key above.
        return .zhHans
    }
}

private enum MenuL10n {
    private static func value(
        zh: String,
        en: String
    ) -> String {
        MenuLanguage.current == .zhHans
            ? zh
            : en
    }

    static var idle: String {
        value(zh: "待机", en: "Idle")
    }
    static var busy: String {
        value(zh: "处理中", en: "Busy")
    }
    static var ok: String {
        value(zh: "正常", en: "OK")
    }
    static var error: String {
        value(zh: "错误", en: "Error")
    }
    static var projects: String {
        value(zh: "项目", en: "Projects")
    }
    static var addProject: String {
        value(zh: "添加项目…", en: "Add Project…")
    }
    static var addProjectPrompt: String {
        value(zh: "添加项目", en: "Add Project")
    }
    static var addProjectMessage: String {
        value(
            zh: "选择一个或多个独立项目目录，AgentInjectionIII 会分别监听。",
            en: "Choose one or more independent project directories for AgentInjectionIII to watch."
        )
    }
    static var addProjectHelp: String {
        value(
            zh: "添加独立项目目录",
            en: "Add independent project directory"
        )
    }
    static var removeProjectHelp: String {
        value(
            zh: "移除项目",
            en: "Remove project"
        )
    }
    static var noProjects: String {
        value(
            zh: "尚未添加项目目录。",
            en: "No project directories registered."
        )
    }
    static var unmatchedRuntimes: String {
        value(
            zh: "未匹配的运行实例",
            en: "Unmatched Runtime Sessions"
        )
    }
    static var noMatchingRuntime: String {
        value(
            zh: "没有匹配的运行实例",
            en: "No matching runtime"
        )
    }
    static var injectAll: String {
        value(
            zh: "注入所有已修改文件",
            en: "Inject All Changed Files"
        )
    }
    static var hotKeyDescription: String {
        value(
            zh: "Control + - 会按项目路由修改文件，只发送到该项目已选择的设备。",
            en: "Control + - routes each changed source to its owning project and selected runtime devices."
        )
    }
    static var daemonUnavailable: String {
        value(
            zh: "injectiond 正在启动或当前不可用",
            en: "injectiond is starting or unavailable"
        )
    }
    static var quit: String {
        value(
            zh: "退出 AgentInjectionIII",
            en: "Quit AgentInjectionIII"
        )
    }
    static var runtime: String {
        value(zh: "运行实例", en: "Runtime")
    }
    static var selectedDevice: String {
        value(
            zh: "注入到已选设备",
            en: "Inject → Selected Device"
        )
    }
    static var noDeviceSelected: String {
        value(
            zh: "未选择设备",
            en: "No Device Selected"
        )
    }
    static var stateHelpPrefix: String {
        value(
            zh: "状态：",
            en: "State: "
        )
    }

    static func changed(
        _ count: Int
    ) -> String {
        MenuLanguage.current == .zhHans
            ? "\(count) 个修改"
            : "\(count) changed"
    }

    static func injectDevices(
        _ count: Int
    ) -> String {
        MenuLanguage.current == .zhHans
            ? "注入到 \(count) 台设备"
            : "Inject → \(count) Devices"
    }

    static func includeRuntimeHelp(
        project: String
    ) -> String {
        MenuLanguage.current == .zhHans
            ? "将此运行实例包含在 \(project) 的热重载中。"
            : "Include this runtime in injections for \(project)."
    }

    static func updated(
        _ time: String
    ) -> String {
        MenuLanguage.current == .zhHans
            ? "更新于 \(time)"
            : "Updated \(time)"
    }
}

private enum MenuInjectionState {
    case idle
    case busy
    case ok
    case error

    var title: String {
        switch self {
        case .idle:
            return MenuL10n.idle
        case .busy:
            return MenuL10n.busy
        case .ok:
            return MenuL10n.ok
        case .error:
            return MenuL10n.error
        }
    }

    var color: Color {
        switch self {
        case .idle:
            return .gray
        case .busy:
            return .orange
        case .ok:
            return .green
        case .error:
            return .red
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "circle"
        case .busy:
            return "clock.fill"
        case .ok:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        }
    }
}

@main
struct AgentInjectionIIIApp: App {
    @StateObject private var model =
        MenuStatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
                .frame(width: 430)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .task {
                    model.refreshDiagnostics()
                }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                Circle()
                    .fill(model.statusLightColor)
                    .frame(width: 7, height: 7)
            }
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
    @Published private var injectingProjectIDs =
        Set<String>()
    @Published private var injectingTargetIDs =
        Set<String>()
    @Published private var projectInjectionErrors:
        [String: String] = [:]
    @Published private var targetInjectionErrors:
        [String: String] = [:]
    @Published private var deselectedTargetKeys:
        Set<String>

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
    private static let deselectedTargetsDefaultsKey =
        "AgentInjectionIII.deselectedRuntimeTargets"

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
        self.deselectedTargetKeys = Set(
            UserDefaults.standard.stringArray(
                forKey:
                    Self.deselectedTargetsDefaultsKey
            ) ?? []
        )
        self.daemonController =
            DaemonController(
                socketPath: socketPath,
                projectRoots: roots
            )
    }

    var statusTitle: String {
        "AgentInjectionIII \(statusLightState.title)"
    }

    var symbolName: String {
        statusLightState.symbolName
    }

    var statusLightColor: Color {
        statusLightState.color
    }

    var statusLightText: String {
        statusLightState.title
    }

    private var statusLightState:
        MenuInjectionState {
        if connectionError != nil ||
           manualInjectionError != nil ||
           diagnostics?.lastError.error != nil ||
           !projectInjectionErrors.isEmpty {
            return .error
        }

        if !injectingProjectIDs.isEmpty {
            return .busy
        }

        let hasConnectedRuntime =
            projects?.projects.contains {
                project in
                targets(for: project).contains {
                    $0.connected
                }
            } ?? false

        return hasConnectedRuntime
            ? .ok
            : .idle
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
            Task { @MainActor in
                self?.refreshStatus()
            }
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
        projectID: String? = nil
    ) {
        let candidates =
            (projects?.projects ?? [])
                .filter {
                    projectID == nil ||
                    $0.id == projectID
                }
                .filter {
                    !(pending(
                        for: $0.id
                    )?.files.isEmpty ?? true)
                }

        guard !candidates.isEmpty else {
            return
        }

        var requests: [(
            projectID: String,
            targetIDs: [String]
        )] = []

        var immediateErrors:
            [String: String] = [:]

        for project in candidates {
            let matchedTargets =
                targets(for: project)
                    .filter(\.connected)
            let selected =
                matchedTargets.filter {
                    isTargetSelected(
                        $0,
                        for: project.id
                    )
                }

            if selected.isEmpty {
                immediateErrors[project.id] =
                    matchedTargets.isEmpty
                    ? "No connected runtime is associated with \(project.displayName)."
                    : "No runtime device is selected for \(project.displayName)."
                continue
            }

            requests.append(
                (
                    projectID: project.id,
                    targetIDs:
                        selected.map(\.id)
                )
            )
        }

        for (projectID, message)
            in immediateErrors {
            projectInjectionErrors[
                projectID
            ] = message
        }

        guard !requests.isEmpty else {
            manualInjectionError =
                immediateErrors.values.first
            return
        }

        let socketPath = socketPath
        let projectIDs =
            Set(requests.map(\.projectID))
        let targetIDs =
            Set(requests.flatMap(\.targetIDs))

        injectingProjectIDs.formUnion(
            projectIDs
        )
        injectingTargetIDs.formUnion(
            targetIDs
        )
        for projectID in projectIDs {
            projectInjectionErrors[
                projectID
            ] = nil
        }
        for targetID in targetIDs {
            targetInjectionErrors[
                targetID
            ] = nil
        }
        manualInjectionError = nil

        worker.async { [weak self] in
            var projectErrors:
                [String: String] = [:]
            var targetErrors:
                [String: String] = [:]

            for request in requests {
                do {
                    let response =
                        try UnixSocketClient(
                            socketPath: socketPath
                        ).send(
                            ControlRequest(
                                action:
                                    .injectPending,
                                targets:
                                    request.targetIDs,
                                projectID:
                                    request.projectID
                            )
                        )

                    if !response.ok {
                        let message =
                            response.error?.message
                            ?? "Injection failed."
                        projectErrors[
                            request.projectID
                        ] = message
                        for targetID
                            in request.targetIDs {
                            targetErrors[
                                targetID
                            ] = message
                        }
                    }
                } catch {
                    let message =
                        String(describing: error)
                    projectErrors[
                        request.projectID
                    ] = message
                    for targetID
                        in request.targetIDs {
                        targetErrors[
                            targetID
                        ] = message
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.injectingProjectIDs
                    .subtract(projectIDs)
                self.injectingTargetIDs
                    .subtract(targetIDs)

                for projectID in projectIDs {
                    self.projectInjectionErrors[
                        projectID
                    ] = projectErrors[
                        projectID
                    ]
                }
                for targetID in targetIDs {
                    self.targetInjectionErrors[
                        targetID
                    ] = targetErrors[
                        targetID
                    ]
                }

                self.manualInjectionError =
                    projectErrors.values.first
                self.refreshStatus()
                self.refreshDiagnostics()
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.prompt =
            MenuL10n.addProjectPrompt
        panel.message =
            MenuL10n.addProjectMessage
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

    func isTargetSelected(
        _ target: RuntimeTarget,
        for projectID: String
    ) -> Bool {
        !deselectedTargetKeys.contains(
            targetSelectionKey(
                target,
                projectID: projectID
            )
        )
    }

    func setTargetSelected(
        _ target: RuntimeTarget,
        projectID: String,
        selected: Bool
    ) {
        let key = targetSelectionKey(
            target,
            projectID: projectID
        )

        if selected {
            deselectedTargetKeys.remove(key)
        } else {
            deselectedTargetKeys.insert(key)
        }

        UserDefaults.standard.set(
            Array(deselectedTargetKeys)
                .sorted(),
            forKey:
                Self.deselectedTargetsDefaultsKey
        )
    }

    func projectStatusColor(
        _ project: ProjectSessionSummary
    ) -> Color {
        projectState(project).color
    }

    func projectStatusText(
        _ project: ProjectSessionSummary
    ) -> String {
        projectState(project).title
    }

    func targetStatusColor(
        _ target: RuntimeTarget
    ) -> Color {
        targetState(target).color
    }

    func targetStatusText(
        _ target: RuntimeTarget
    ) -> String {
        targetState(target).title
    }

    private func projectState(
        _ project: ProjectSessionSummary
    ) -> MenuInjectionState {
        if injectingProjectIDs.contains(
            project.id
        ) {
            return .busy
        }

        if projectInjectionErrors[
            project.id
        ] != nil {
            return .error
        }

        return targets(for: project)
            .contains(where: \.connected)
            ? .ok
            : .idle
    }

    private func targetState(
        _ target: RuntimeTarget
    ) -> MenuInjectionState {
        if injectingTargetIDs.contains(
            target.id
        ) {
            return .busy
        }

        if targetInjectionErrors[
            target.id
        ] != nil {
            return .error
        }

        return target.connected
            ? .ok
            : .idle
    }

    private func targetSelectionKey(
        _ target: RuntimeTarget,
        projectID: String
    ) -> String {
        [
            projectID,
            target.isLocal
                ? "local"
                : (target.peerAddress
                   ?? "remote"),
            target.projectRoot ?? "",
            target.executable ?? "",
            target.platform ?? "",
            target.arch ?? ""
        ]
        .joined(separator: "|")
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
                self?.daemonController.ensureRunning()
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
                self?.daemonController.ensureRunning()
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
        let fileManager =
            FileManager.default
        let file =
            UnifiedDiagnosticLog
                .defaultLogURL

        do {
            try fileManager
                .createDirectory(
                    at:
                        file
                            .deletingLastPathComponent(),
                    withIntermediateDirectories:
                        true
                )

            if !fileManager.fileExists(
                atPath: file.path
            ) {
                fileManager.createFile(
                    atPath: file.path,
                    contents: nil
                )
            }

            // Remove the legacy split log so there is only one
            // documented diagnostic location going forward.
            let legacy =
                file
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "injectiond.log"
                    )
            try? fileManager.removeItem(
                at: legacy
            )

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
            spacing: 6
        ) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.statusLightColor)
                    .frame(width: 9, height: 9)
                    .help(
                        MenuL10n.stateHelpPrefix +
                        model.statusLightText
                    )

                Text("AgentInjectionIII")
                    .font(.headline)

                Text(model.statusLightText)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(
                        model.statusLightColor
                    )

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
                    MenuL10n.injectAll
                ) {
                    model.injectPendingChanges()
                }
                .keyboardShortcut(
                    "-",
                    modifiers: [.control]
                )

                Text(
                    MenuL10n.hotKeyDescription
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
                    MenuL10n.daemonUnavailable,
                    systemImage:
                        "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                if let updated =
                    model.lastUpdated {
                    Text(
                        MenuL10n.updated(
                            updated.formatted(
                                date: .omitted,
                                time: .standard
                            )
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(
                    MenuL10n.quit
                ) {
                    model.shutdown()
                    NSApplication.shared
                        .terminate(nil)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var projectsSection: some View {
        HStack {
            Text(MenuL10n.projects)
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
            .help(MenuL10n.addProjectHelp)
        }

        let projects =
            model.projects?.projects ?? []

        if projects.isEmpty {
            Text(MenuL10n.noProjects)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(MenuL10n.addProject) {
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
                spacing: 3
            ) {
                Label(
                    MenuL10n.unmatchedRuntimes,
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
                        .padding(
                            .leading,
                            18
                        )
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
            spacing: 3
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        model.projectStatusColor(
                            project
                        )
                    )
                    .frame(width: 8, height: 8)
                    .help(
                        MenuL10n.stateHelpPrefix +
                        model.projectStatusText(
                            project
                        )
                    )

                Image(
                    systemName: "folder"
                )

                Text(project.displayName)
                    .font(.subheadline)
                    .bold()

                Spacer()

                if project.pendingCount > 0 {
                    Text(
                        MenuL10n.changed(
                            project.pendingCount
                        )
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
                        systemName:
                            "minus.circle"
                    )
                }
                .buttonStyle(.borderless)
                .help(
                    MenuL10n
                        .removeProjectHelp
                )
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
                    MenuL10n
                        .noMatchingRuntime,
                    systemImage:
                        "iphone.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            } else {
                ForEach(
                    targets,
                    id: \.id
                ) { target in
                    Toggle(
                        isOn: Binding(
                            get: {
                                model
                                    .isTargetSelected(
                                        target,
                                        for:
                                            project.id
                                    )
                            },
                            set: {
                                model
                                    .setTargetSelected(
                                        target,
                                        projectID:
                                            project.id,
                                        selected: $0
                                    )
                            }
                        )
                    ) {
                        runtimeRow(target)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, 18)
                    .help(
                        MenuL10n
                            .includeRuntimeHelp(
                                project:
                                    project
                                        .displayName
                            )
                    )
                }
            }

            if let pending =
                model.pending(
                    for: project.id
                ),
               !pending.files.isEmpty {
                ForEach(
                    Array(
                        pending.files.suffix(3)
                    ),
                    id: \.self
                ) { file in
                    HStack(spacing: 5) {
                        Image(
                            systemName: "doc"
                        )
                        .foregroundStyle(
                            .secondary
                        )

                        Text(
                            URL(
                                fileURLWithPath:
                                    file
                            )
                            .lastPathComponent
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                        .lineLimit(1)
                    }
                    .padding(
                        .leading,
                        18
                    )
                }

                let selectedCount =
                    targets.filter {
                        $0.connected &&
                        model.isTargetSelected(
                            $0,
                            for: project.id
                        )
                    }.count

                Button(
                    selectedCount > 1
                        ? MenuL10n
                            .injectDevices(
                                selectedCount
                            )
                        : selectedCount == 1
                            ? MenuL10n
                                .selectedDevice
                            : MenuL10n
                                .noDeviceSelected
                ) {
                    model
                        .injectPendingChanges(
                            projectID:
                                project.id
                        )
                }
                .disabled(
                    selectedCount == 0
                )
                .padding(
                    .leading,
                    18
                )
            }
        }
        .padding(.vertical, 2)
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
                spacing: 0
            ) {
                Text(
                    target.executable
                        .map {
                            URL(
                                fileURLWithPath:
                                    $0
                            )
                            .lastPathComponent
                        }
                    ?? target.platform
                    ?? MenuL10n.runtime
                )
                .font(.caption)

                Text(
                    [
                        target.peerAddress,
                        target.platform,
                        target.arch
                    ]
                    .compactMap { $0 }
                    .joined(
                        separator: " · "
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(
                        model.targetStatusColor(
                            target
                        )
                    )
                    .frame(
                        width: 7,
                        height: 7
                    )

                Text(
                    model.targetStatusText(
                        target
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
