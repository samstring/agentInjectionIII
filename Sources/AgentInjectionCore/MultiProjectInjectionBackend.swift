import Foundation

/// Extra routing surface used by ControlRouter when a daemon manages more than
/// one independent project root. Existing InjectionBackend callers remain
/// source-compatible and continue to use the legacy methods.
public protocol ProjectRoutingBackend: InjectionBackend {
    func projects() -> ProjectsResult

    func addProject(
        root: String
    ) -> Result<ProjectSessionSummary, ControlError>

    func removeProject(
        id: String
    ) -> Result<ProjectsResult, ControlError>

    func pendingChanges(
        projectID: String
    ) -> Result<PendingChangesResult, ControlError>

    func injectPending(
        projectID: String,
        target: String?
    ) -> BackendInjectionResponse

    func inject(
        files: [String],
        projectID: String,
        target: String?
    ) -> BackendInjectionResponse

    func doctor(
        path: String?,
        projectID: String
    ) -> Result<DoctorReport, ControlError>

    func diagnostics(
        limit: Int?,
        projectID: String
    ) -> Result<DiagnosticsResult, ControlError>

    func targets(
        projectID: String
    ) -> Result<TargetsResult, ControlError>
}

public enum ProjectSessionIdentity {
    public static func standardizedRoot(
        _ root: String
    ) -> String {
        URL(
            fileURLWithPath: NSString(
                string: root
            ).expandingTildeInPath
        )
        .standardizedFileURL
        .path
    }

    public static func id(
        forRoot root: String
    ) -> String {
        let value = standardizedRoot(root)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(
            format: "project-%016llx",
            hash
        )
    }

    public static func contains(
        source: String,
        root: String
    ) -> Bool {
        let source = standardizedRoot(source)
        let root = standardizedRoot(root)
        return source == root ||
            source.hasPrefix(root + "/")
    }

    public static func runtimeMatches(
        projectRoot: String,
        runtimeProjectRoot: String?
    ) -> Bool {
        guard let runtimeProjectRoot,
              !runtimeProjectRoot.isEmpty else {
            return false
        }

        let project = standardizedRoot(projectRoot)
        let runtime = standardizedRoot(runtimeProjectRoot)

        return project == runtime ||
            runtime.hasPrefix(project + "/") ||
            project.hasPrefix(runtime + "/")
    }
}

private final class ProjectInjectionSession {
    let id: String
    let root: String
    let backend: InjectionNextRuntimeBackend

    init(
        id: String,
        root: String,
        backend: InjectionNextRuntimeBackend
    ) {
        self.id = id
        self.root = root
        self.backend = backend
    }

    var displayName: String {
        let name = URL(
            fileURLWithPath: root
        ).lastPathComponent
        return name.isEmpty ? root : name
    }
}

/// One daemon, one InjectionNext listener, many independent project sessions.
///
/// Every project session owns its existing single-project backend (compiler,
/// watcher, pending changes, diagnostics). The manager only adds routing and
/// aggregation; it does not duplicate InjectionIII compile/injection logic.
public final class MultiProjectInjectionBackend:
    ProjectRoutingBackend,
    @unchecked Sendable {

    public let name = "injectionnext-multi-project"

    private let runtimeServer: InjectionNextRuntimeServer
    private let traceServer: AgentTraceServer
    private let derivedDataRoot: String?
    private let codeSigningIdentity: String?
    private let deviceTesting: Bool
    private let deviceLibraries: [String]

    private let stateLock = NSLock()
    private var selectedXcodePath: String?
    private var sessions: [String: ProjectInjectionSession] = [:]
    private var sessionOrder: [String] = []

    public init(
        runtimeServer: InjectionNextRuntimeServer,
        traceServer: AgentTraceServer,
        projectRoots: [String] = [],
        derivedDataRoot: String? = nil,
        codeSigningIdentity: String? = nil,
        xcodePath: String? = nil,
        deviceTesting: Bool = false,
        deviceLibraries: [String] = [
            "-framework", "XCTest",
            "-lXCTestSwiftSupport"
        ]
    ) {
        self.runtimeServer = runtimeServer
        self.traceServer = traceServer
        self.derivedDataRoot = derivedDataRoot
        self.codeSigningIdentity = codeSigningIdentity
        self.selectedXcodePath = xcodePath
        self.deviceTesting = deviceTesting
        self.deviceLibraries = deviceLibraries

        for root in projectRoots {
            _ = addProject(root: root)
        }
    }

    // MARK: - Project routing

    public func projects() -> ProjectsResult {
        let current = snapshotSessions()
        let targets = runtimeServer.targets()

        let summaries = current.map { session in
            let pending = session.backend.pendingChanges()
            let targetIDs = targets
                .filter {
                    target($0, belongsTo: session, among: current)
                }
                .map(\.id)

            return ProjectSessionSummary(
                id: session.id,
                root: session.root,
                displayName: session.displayName,
                watching: pending.watching,
                pendingCount: pending.files.count,
                targetIDs: targetIDs
            )
        }

        let unmatched = targets.filter {
            matchingSession(
                for: $0,
                among: current
            ) == nil
        }

        return ProjectsResult(
            projects: summaries,
            unmatchedTargets: unmatched
        )
    }

    public func addProject(
        root: String
    ) -> Result<ProjectSessionSummary, ControlError> {
        let normalized =
            ProjectSessionIdentity.standardizedRoot(root)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: normalized,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {
            return .failure(
                ControlError(
                    code: "PROJECT_ROOT_NOT_FOUND",
                    message: "Project root does not exist or is not a directory: \(normalized)"
                )
            )
        }

        let id = ProjectSessionIdentity.id(
            forRoot: normalized
        )

        stateLock.lock()
        if let existing = sessions[id] {
            stateLock.unlock()
            return .success(
                summary(
                    for: existing,
                    sessions: snapshotSessions()
                )
            )
        }
        let xcodePath = selectedXcodePath
        stateLock.unlock()

        let backend = InjectionNextRuntimeBackend(
            runtimeServer: runtimeServer,
            traceServer: traceServer,
            projectRoot: normalized,
            derivedDataRoot: derivedDataRoot,
            codeSigningIdentity: codeSigningIdentity,
            xcodePath: xcodePath,
            deviceTesting: deviceTesting,
            deviceLibraries: deviceLibraries
        )
        let session = ProjectInjectionSession(
            id: id,
            root: normalized,
            backend: backend
        )

        stateLock.lock()
        if sessions[id] == nil {
            sessions[id] = session
            sessionOrder.append(id)
        }
        let stored = sessions[id]!
        stateLock.unlock()

        return .success(
            summary(
                for: stored,
                sessions: snapshotSessions()
            )
        )
    }

    public func removeProject(
        id: String
    ) -> Result<ProjectsResult, ControlError> {
        stateLock.lock()
        guard sessions.removeValue(
            forKey: id
        ) != nil else {
            stateLock.unlock()
            return .failure(
                ControlError(
                    code: "PROJECT_NOT_FOUND",
                    message: "Project session not found: \(id)"
                )
            )
        }
        sessionOrder.removeAll { $0 == id }
        stateLock.unlock()

        return .success(projects())
    }

    public func pendingChanges(
        projectID: String
    ) -> Result<PendingChangesResult, ControlError> {
        withSession(projectID) {
            .success($0.backend.pendingChanges())
        }
    }

    public func injectPending(
        projectID: String,
        target: String?
    ) -> BackendInjectionResponse {
        guard let session = session(id: projectID) else {
            return projectNotFoundInjection(projectID)
        }

        let pending = session.backend.pendingChanges()
        guard !pending.files.isEmpty else {
            return BackendInjectionResponse(
                results: []
            )
        }

        return inject(
            files: pending.files,
            projectID: projectID,
            target: target
        )
    }

    public func inject(
        files: [String],
        projectID: String,
        target: String?
    ) -> BackendInjectionResponse {
        guard let session = session(id: projectID) else {
            return projectNotFoundInjection(projectID)
        }

        let outside = files.filter {
            !ProjectSessionIdentity.contains(
                source: $0,
                root: session.root
            )
        }
        guard outside.isEmpty else {
            let error = ControlError(
                code: "SOURCE_PROJECT_MISMATCH",
                message: "One or more sources are outside project \(session.root): \(outside.joined(separator: ", "))"
            )
            return BackendInjectionResponse(
                results: files.map {
                    InjectionResult(
                        file: ProjectSessionIdentity.standardizedRoot($0),
                        compiled: false,
                        injected: false,
                        message: error.message
                    )
                },
                error: error
            )
        }

        if let target {
            guard selectedTarget(
                for: session,
                explicit: target
            ) != nil else {
                return targetMismatchInjection(
                    target: target,
                    projectID: projectID
                )
            }

            return session.backend.inject(
                files: files,
                target: target
            )
        }

        let matchingTargets = targets(
            for: session
        )
        .filter(\.connected)

        guard !matchingTargets.isEmpty else {
            let error = ControlError(
                code: "RUNTIME_NOT_CONNECTED",
                message: "No connected runtime is associated with project \(session.root)."
            )
            return BackendInjectionResponse(
                results: files.map {
                    InjectionResult(
                        file: ProjectSessionIdentity.standardizedRoot($0),
                        compiled: false,
                        injected: false,
                        message: error.message
                    )
                },
                error: error
            )
        }

        var results: [InjectionResult] = []
        var firstError: ControlError?

        for runtime in matchingTargets {
            let response = session.backend.inject(
                files: files,
                target: runtime.id
            )
            results.append(
                contentsOf: response.results
            )
            if firstError == nil {
                firstError = response.error
            }
        }

        return BackendInjectionResponse(
            results: results,
            error: firstError
        )
    }

    public func doctor(
        path: String?,
        projectID: String
    ) -> Result<DoctorReport, ControlError> {
        withSession(projectID) { session in
            .success(
                session.backend.doctor(
                    path: path,
                    target: selectedTarget(
                        for: session,
                        explicit: nil
                    )
                )
            )
        }
    }

    public func diagnostics(
        limit: Int?,
        projectID: String
    ) -> Result<DiagnosticsResult, ControlError> {
        withSession(projectID) { session in
            let target = selectedTarget(
                for: session,
                explicit: nil
            )
            let base = session.backend.diagnostics(
                limit: limit,
                target: target
            )
            let filteredTargets = targets(
                for: session
            )

            return .success(
                DiagnosticsResult(
                    generatedAt: base.generatedAt,
                    status: base.status,
                    targets: TargetsResult(
                        targets: filteredTargets
                    ),
                    trace: base.trace,
                    compilerState: base.compilerState,
                    doctor: base.doctor,
                    logs: base.logs,
                    events: base.events,
                    lastError: base.lastError
                )
            )
        }
    }

    public func targets(
        projectID: String
    ) -> Result<TargetsResult, ControlError> {
        withSession(projectID) {
            .success(
                TargetsResult(
                    targets: targets(for: $0)
                )
            )
        }
    }

    // MARK: - Legacy InjectionBackend

    public func status() -> BackendStatus {
        let current = snapshotSessions()
        let allTargets = runtimeServer.targets()
        let connected = allTargets.filter {
            $0.connected &&
            matchingSession(
                for: $0,
                among: current
            ) != nil
        }
        let latest = connected.last

        return BackendStatus(
            name: name,
            ready: !connected.isEmpty,
            appConnected: !connected.isEmpty,
            capabilities: [
                "status",
                "diagnostics",
                "source-inject",
                "pending-changes",
                "load-dylib",
                "swift",
                "objc",
                "objc++",
                "xcode-build-log",
                "screenshot",
                "trace",
                "targets",
                "device-injection",
                "touch-capture",
                "touch-replay",
                "logs",
                "unhide-symbols",
                "swiftui-prepare",
                "xcode-selection",
                "last-error",
                "lifecycle-events",
                "device-testing",
                "runtime-env",
                "call-order",
                "instance-counts",
                "compiler-interception",
                "xctest-results",
                "reorder-project",
                "xprobe",
                "eval",
                "multi-project"
            ],
            platform: latest?.platform,
            arch: latest?.arch,
            temporaryPath: latest?.temporaryPath,
            detail: "\(current.count) project session(s), \(connected.count) matched runtime target(s), \(allTargets.count - connected.count) unmatched target(s)."
        )
    }

    public func targets() -> TargetsResult {
        TargetsResult(
            targets: runtimeServer.targets()
        )
    }

    public func pendingChanges() -> PendingChangesResult {
        let current = snapshotSessions()
        let pending = current.map {
            $0.backend.pendingChanges()
        }

        return PendingChangesResult(
            projectRoot: current.count == 1
                ? current[0].root
                : nil,
            watching: pending.contains {
                $0.watching
            },
            files: pending.flatMap(\.files)
        )
    }

    public func injectPending(
        target: String?
    ) -> BackendInjectionResponse {
        if let target,
           let session = sessionForTarget(target) {
            return session.backend.injectPending(
                target: target
            )
        }

        let current = snapshotSessions()
        if current.count == 1 {
            if let target {
                return current[0].backend.injectPending(
                    target: target
                )
            }
            return injectPending(
                projectID: current[0].id,
                target: nil
            )
        }

        var all: [InjectionResult] = []
        var firstError: ControlError?

        for session in current {
            let pending =
                session.backend.pendingChanges()
            guard !pending.files.isEmpty else {
                continue
            }

            let response = injectPending(
                projectID: session.id,
                target: nil
            )
            all.append(contentsOf: response.results)
            if firstError == nil {
                firstError = response.error
            }
        }

        return BackendInjectionResponse(
            results: all,
            error: firstError
        )
    }

    public func inject(
        files: [String],
        target: String?
    ) -> BackendInjectionResponse {
        let current = snapshotSessions()

        if current.count == 1 {
            if let target {
                return current[0].backend.inject(
                    files: files,
                    target: target
                )
            }
            return inject(
                files: files,
                projectID: current[0].id,
                target: nil
            )
        }

        var grouped: [String: [String]] = [:]
        var unresolved: [String] = []

        for file in files {
            if let session = sessionForSource(
                file,
                among: current
            ) {
                grouped[session.id, default: []]
                    .append(file)
            } else {
                unresolved.append(file)
            }
        }

        var results = unresolved.map {
            InjectionResult(
                file: ProjectSessionIdentity.standardizedRoot($0),
                compiled: false,
                injected: false,
                message: "Source is not inside a registered project root."
            )
        }
        var firstError: ControlError? =
            unresolved.isEmpty
            ? nil
            : ControlError(
                code: "PROJECT_FOR_SOURCE_NOT_FOUND",
                message: "Some sources are not inside a registered project root."
            )

        for session in current {
            guard let group = grouped[session.id],
                  !group.isEmpty else {
                continue
            }

            let selected: String?
            if let target {
                guard let targetSession =
                        sessionForTarget(target),
                      targetSession.id == session.id else {
                    let error = ControlError(
                        code: "TARGET_PROJECT_MISMATCH",
                        message: "Target \(target) does not belong to project \(session.root)."
                    )
                    results.append(
                        contentsOf: group.map {
                            InjectionResult(
                                file: ProjectSessionIdentity.standardizedRoot($0),
                                compiled: false,
                                injected: false,
                                message: error.message
                            )
                        }
                    )
                    if firstError == nil {
                        firstError = error
                    }
                    continue
                }
                selected = target
            } else {
                selected = selectedTarget(
                    for: session,
                    explicit: nil
                )
            }

            let response = session.backend.inject(
                files: group,
                target: selected
            )
            results.append(contentsOf: response.results)
            if firstError == nil {
                firstError = response.error
            }
        }

        return BackendInjectionResponse(
            results: results,
            error: firstError
        )
    }

    public func loadDylib(
        path: String,
        target: String?
    ) -> BackendInjectionResponse {
        guard let backend =
                backendForRuntimeOperation(
                    target: target
                ) else {
            return noProjectInjection()
        }
        return backend.loadDylib(
            path: path,
            target: target
        )
    }

    public func doctor(
        path: String?
    ) -> DoctorReport {
        let current = snapshotSessions()

        if let path,
           let session = sessionForSource(
                path,
                among: current
           ) {
            return session.backend.doctor(
                path: path,
                target: selectedTarget(
                    for: session,
                    explicit: nil
                )
            )
        }

        if current.count == 1 {
            let session = current[0]
            return session.backend.doctor(
                path: path,
                target: selectedTarget(
                    for: session,
                    explicit: nil
                )
            )
        }

        let checks = current.map {
            DoctorCheck(
                name: "project_\($0.displayName)",
                state: .pass,
                message: "Registered project session: \($0.root)"
            )
        } + [
            DoctorCheck(
                name: "project_selection",
                state: current.isEmpty
                    ? .warning
                    : .pass,
                message: current.isEmpty
                    ? "No project sessions are registered."
                    : "\(current.count) project sessions are registered; pass projectID or a source path for project-specific doctor checks."
            )
        ]

        return DoctorReport(
            ready: true,
            checks: checks
        )
    }

    public func diagnostics(
        limit: Int?
    ) -> DiagnosticsResult {
        let current = snapshotSessions()

        if current.count == 1 {
            let session = current[0]
            return session.backend.diagnostics(
                limit: limit,
                target: selectedTarget(
                    for: session,
                    explicit: nil
                )
            )
        }

        let scaffold =
            ScaffoldInjectionBackend()
                .diagnostics(limit: limit)

        let representative =
            current.first?.backend.diagnostics(
                limit: limit,
                target: current.first.flatMap {
                    selectedTarget(
                        for: $0,
                        explicit: nil
                    )
                }
            )

        return DiagnosticsResult(
            status: status(),
            targets: targets(),
            trace: representative?.trace
                ?? traceServer.status(),
            compilerState:
                representative?.compilerState
                ?? scaffold.compilerState,
            doctor: doctor(path: nil),
            logs: logs(
                since: nil,
                limit: limit
            ),
            events: events(limit: limit),
            lastError: lastError()
        )
    }

    public func screenshot(
        path: String?,
        target: String?
    ) -> Result<ScreenshotResult, ControlError> {
        guard let backend =
                backendForRuntimeOperation(
                    target: target
                ) else {
            return .failure(noProjectError())
        }
        return backend.screenshot(
            path: path,
            target: target
        )
    }

    public func touchCapture(
        target: String?
    ) -> Result<TouchResult, ControlError> {
        guard let backend =
                backendForRuntimeOperation(
                    target: target
                ) else {
            return .failure(noProjectError())
        }
        return backend.touchCapture(
            target: target
        )
    }

    public func touchRead(
        target: String?
    ) -> Result<TouchResult, ControlError> {
        guard let backend =
                backendForRuntimeOperation(
                    target: target
                ) else {
            return .failure(noProjectError())
        }
        return backend.touchRead(
            target: target
        )
    }

    public func touchReplay(
        payload: String,
        target: String?
    ) -> Result<TouchResult, ControlError> {
        guard let backend =
                backendForRuntimeOperation(
                    target: target
                ) else {
            return .failure(noProjectError())
        }
        return backend.touchReplay(
            payload: payload,
            target: target
        )
    }

    public func logs(
        since: Double?,
        limit: Int?
    ) -> LogsResult {
        runtimeServer.logs(
            since: since,
            limit: limit
        )
    }

    public func clearLogs() -> LogsResult {
        runtimeServer.clearLogs()
    }

    public func unhideSymbols()
        -> Result<OperationResult, ControlError> {
        guard let backend = firstBackend() else {
            return .failure(noProjectError())
        }
        return backend.unhideSymbols()
    }

    public func prepareSwiftUISource(
        path: String
    ) -> Result<OperationResult, ControlError> {
        guard let session = sessionForSource(
            path,
            among: snapshotSessions()
        ) ?? singleSession() else {
            return .failure(
                ControlError(
                    code: "PROJECT_FOR_SOURCE_NOT_FOUND",
                    message: "Unable to determine the project for \(path)."
                )
            )
        }
        return session.backend.prepareSwiftUISource(
            path: path
        )
    }

    public func prepareSwiftUIProject()
        -> Result<OperationResult, ControlError> {
        guard let backend = singleSession()?.backend else {
            return .failure(
                ControlError(
                    code: "PROJECT_SELECTION_REQUIRED",
                    message: "prepare_swiftui_project requires exactly one registered project."
                )
            )
        }
        return backend.prepareSwiftUIProject()
    }

    public func setXcodePath(
        path: String
    ) -> Result<OperationResult, ControlError> {
        let developer = URL(
            fileURLWithPath: NSString(
                string: path
            ).expandingTildeInPath
        )
        .appendingPathComponent(
            "Contents/Developer"
        )
        .path

        guard FileManager.default.fileExists(
            atPath: developer
        ) else {
            return .failure(
                ControlError(
                    code: "XCODE_NOT_FOUND",
                    message: "Xcode.app not found or invalid: \(path)"
                )
            )
        }

        stateLock.lock()
        selectedXcodePath = path
        let current = sessionOrder.compactMap {
            sessions[$0]
        }
        stateLock.unlock()

        runtimeServer.setXcodePath(path)
        for session in current {
            _ = session.backend.setXcodePath(
                path: path
            )
        }

        return .success(
            OperationResult(
                message: "Selected Xcode for \(current.count) project session(s): \(path)"
            )
        )
    }

    public func launchXcode()
        -> Result<OperationResult, ControlError> {
        guard let backend = firstBackend() else {
            return .failure(noProjectError())
        }
        return backend.launchXcode()
    }

    public func lastError() -> LastErrorResult {
        for session in snapshotSessions().reversed() {
            let value = session.backend.lastError()
            if value.error != nil {
                return value
            }
        }
        return LastErrorResult()
    }

    public func events(
        limit: Int?
    ) -> InjectionEventsResult {
        let values = snapshotSessions()
            .flatMap {
                $0.backend.events(
                    limit: limit
                ).events
            }
            .sorted {
                $0.timestamp < $1.timestamp
            }

        let final: [InjectionEvent]
        if let limit, limit >= 0 {
            final = Array(values.suffix(limit))
        } else {
            final = values
        }

        return InjectionEventsResult(
            events: final
        )
    }

    public func clearEvents()
        -> InjectionEventsResult {
        for session in snapshotSessions() {
            _ = session.backend.clearEvents()
        }
        return InjectionEventsResult(events: [])
    }

    public func profileSnapshot(
        limit: Int?
    ) -> Result<ProfileResult, ControlError> {
        traceServer.profileSnapshot(
            limit: limit
        )
    }

    public func compilerState() -> CompilerStateResult {
        firstBackend()?.compilerState()
            ?? CompilerStateResult(
                xcodePath: selectedXcodePath,
                frontendPath: nil,
                patchedFrontendPath: nil,
                intercepted: false,
                commandSource: "none",
                note: "No project session is registered."
            )
    }

    public func setCompilerInterception(
        enabled: Bool
    ) -> Result<CompilerStateResult, ControlError> {
        guard let backend = singleSession()?.backend else {
            return .failure(
                ControlError(
                    code: "PROJECT_SELECTION_REQUIRED",
                    message: "compiler_interception currently requires exactly one registered project."
                )
            )
        }
        return backend.setCompilerInterception(
            enabled: enabled
        )
    }

    public func setRuntimeEnvironment(
        _ values: [String: String?],
        target: String?
    ) -> Result<OperationResult, ControlError> {
        guard let backend =
                backendForRuntimeOperation(
                    target: target
                ) else {
            return .failure(noProjectError())
        }
        return backend.setRuntimeEnvironment(
            values,
            target: target
        )
    }

    public func traceStart(
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        traceServer.startTrace(
            filter: filter
        )
    }

    public func traceScope(
        scope: String,
        name: String?,
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        guard let backend = firstBackend() else {
            return .failure(noProjectError())
        }
        return backend.traceScope(
            scope: scope,
            name: name,
            filter: filter
        )
    }

    public func callOrder()
        -> Result<CallOrderResult, ControlError> {
        traceServer.callOrderSnapshot()
    }

    public func instancesStart()
        -> Result<InstanceCountsResult, ControlError> {
        traceServer.instancesStart()
    }

    public func instancesRead()
        -> Result<InstanceCountsResult, ControlError> {
        traceServer.instancesRead()
    }

    public func instancesStop()
        -> Result<InstanceCountsResult, ControlError> {
        traceServer.instancesStop()
    }

    public func testResults(
        limit: Int?
    ) -> TestResultsResult {
        traceServer.injectedTestResults(
            limit: limit
        )
    }

    public func clearTestResults()
        -> TestResultsResult {
        traceServer.clearInjectedTestResults()
    }

    public func reorderProject(
        path: String?,
        apply: Bool
    ) -> Result<ProjectReorderPlan, ControlError> {
        if let path,
           let session = sessionForSource(
                path,
                among: snapshotSessions()
           ) {
            return session.backend.reorderProject(
                path: path,
                apply: apply
            )
        }

        guard let backend = singleSession()?.backend else {
            return .failure(
                ControlError(
                    code: "PROJECT_SELECTION_REQUIRED",
                    message: "reorder_project requires a path inside a registered project when multiple projects are active."
                )
            )
        }
        return backend.reorderProject(
            path: path,
            apply: apply
        )
    }

    public func xprobeSearch(
        pattern: String?
    ) -> Result<XprobeResult, ControlError> {
        guard let backend = firstBackend() else {
            return .failure(noProjectError())
        }
        return backend.xprobeSearch(
            pattern: pattern
        )
    }

    public func xprobeInspect(
        objectID: Int
    ) -> Result<XprobeResult, ControlError> {
        guard let backend = firstBackend() else {
            return .failure(noProjectError())
        }
        return backend.xprobeInspect(
            objectID: objectID
        )
    }

    public func eval(
        objectID: Int,
        code: String
    ) -> Result<EvalResult, ControlError> {
        guard let backend = firstBackend() else {
            return .failure(noProjectError())
        }
        return backend.eval(
            objectID: objectID,
            code: code
        )
    }

    public func traceStop()
        -> Result<TraceResult, ControlError> {
        traceServer.stopTrace()
    }

    public func traceRead(
        limit: Int?
    ) -> Result<TraceResult, ControlError> {
        .success(
            traceServer.readTrace(
                limit: limit
            )
        )
    }

    // MARK: - Helpers

    private func snapshotSessions()
        -> [ProjectInjectionSession] {
        stateLock.lock()
        defer { stateLock.unlock() }

        return sessionOrder.compactMap {
            sessions[$0]
        }
    }

    private func session(
        id: String
    ) -> ProjectInjectionSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessions[id]
    }

    private func singleSession()
        -> ProjectInjectionSession? {
        let current = snapshotSessions()
        return current.count == 1
            ? current[0]
            : nil
    }

    private func firstBackend()
        -> InjectionNextRuntimeBackend? {
        snapshotSessions().first?.backend
    }

    private func withSession<T>(
        _ id: String,
        _ body:
            (ProjectInjectionSession)
            -> Result<T, ControlError>
    ) -> Result<T, ControlError> {
        guard let session = session(id: id) else {
            return .failure(
                ControlError(
                    code: "PROJECT_NOT_FOUND",
                    message: "Project session not found: \(id)"
                )
            )
        }
        return body(session)
    }

    private func summary(
        for session: ProjectInjectionSession,
        sessions: [ProjectInjectionSession]
    ) -> ProjectSessionSummary {
        let pending =
            session.backend.pendingChanges()
        let targetIDs =
            runtimeServer.targets()
                .filter {
                    target(
                        $0,
                        belongsTo: session,
                        among: sessions
                    )
                }
                .map(\.id)

        return ProjectSessionSummary(
            id: session.id,
            root: session.root,
            displayName: session.displayName,
            watching: pending.watching,
            pendingCount: pending.files.count,
            targetIDs: targetIDs
        )
    }

    private func targets(
        for session: ProjectInjectionSession
    ) -> [RuntimeTarget] {
        let current = snapshotSessions()
        return runtimeServer.targets().filter {
            target(
                $0,
                belongsTo: session,
                among: current
            )
        }
    }

    private func target(
        _ target: RuntimeTarget,
        belongsTo session: ProjectInjectionSession,
        among sessions: [ProjectInjectionSession]
    ) -> Bool {
        matchingSession(
            for: target,
            among: sessions
        )?.id == session.id
    }

    private func matchingSession(
        for target: RuntimeTarget,
        among sessions: [ProjectInjectionSession]
    ) -> ProjectInjectionSession? {
        guard let runtimeRoot =
                target.projectRoot,
              !runtimeRoot.isEmpty else {
            return sessions.count == 1
                ? sessions[0]
                : nil
        }

        let runtime =
            ProjectSessionIdentity
                .standardizedRoot(runtimeRoot)

        if let exact = sessions.first(
            where: { $0.root == runtime }
        ) {
            return exact
        }

        let containing = sessions
            .filter {
                runtime.hasPrefix(
                    $0.root + "/"
                )
            }
            .sorted {
                $0.root.count > $1.root.count
            }

        if let first = containing.first {
            return first
        }

        let children = sessions.filter {
            $0.root.hasPrefix(
                runtime + "/"
            )
        }

        return children.count == 1
            ? children[0]
            : nil
    }

    private func sessionForTarget(
        _ targetID: String
    ) -> ProjectInjectionSession? {
        guard let target =
                runtimeServer.targets()
                .first(
                    where: {
                        $0.id == targetID
                    }
                ) else {
            return nil
        }

        return matchingSession(
            for: target,
            among: snapshotSessions()
        )
    }

    private func sessionForSource(
        _ source: String,
        among sessions: [ProjectInjectionSession]
    ) -> ProjectInjectionSession? {
        sessions
            .filter {
                ProjectSessionIdentity.contains(
                    source: source,
                    root: $0.root
                )
            }
            .sorted {
                $0.root.count > $1.root.count
            }
            .first
    }

    private func selectedTarget(
        for session: ProjectInjectionSession,
        explicit: String?
    ) -> String? {
        if let explicit {
            guard let target =
                    runtimeServer.targets()
                    .first(
                        where: {
                            $0.id == explicit
                        }
                    ) else {
                return nil
            }

            if target.projectRoot == nil {
                return explicit
            }

            return matchingSession(
                for: target,
                among: snapshotSessions()
            )?.id == session.id
                ? explicit
                : nil
        }

        return targets(for: session)
            .filter(\.connected)
            .last?
            .id
    }

    private func backendForRuntimeOperation(
        target: String?
    ) -> InjectionNextRuntimeBackend? {
        if let target,
           let session =
                sessionForTarget(target) {
            return session.backend
        }

        return singleSession()?.backend
            ?? firstBackend()
    }

    private func projectNotFoundInjection(
        _ projectID: String
    ) -> BackendInjectionResponse {
        let error = ControlError(
            code: "PROJECT_NOT_FOUND",
            message: "Project session not found: \(projectID)"
        )
        return BackendInjectionResponse(
            results: [],
            error: error
        )
    }

    private func targetMismatchInjection(
        target: String,
        projectID: String
    ) -> BackendInjectionResponse {
        let error = ControlError(
            code: "TARGET_PROJECT_MISMATCH",
            message: "Runtime target \(target) is not associated with project \(projectID)."
        )
        return BackendInjectionResponse(
            results: [],
            error: error
        )
    }

    private func noProjectError()
        -> ControlError {
        ControlError(
            code: "PROJECT_NOT_REGISTERED",
            message: "No project session is registered."
        )
    }

    private func noProjectInjection()
        -> BackendInjectionResponse {
        BackendInjectionResponse(
            results: [],
            error: noProjectError()
        )
    }
}
