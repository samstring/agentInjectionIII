import Foundation

public enum ControlAction: String, Codable, Sendable {
    case status
    case inject
    case pendingChanges = "pending_changes"
    case injectPending = "inject_pending"
    case loadDylib = "load_dylib"
    case doctor
    case diagnostics
    case screenshot
    case traceStart = "trace_start"
    case traceStop = "trace_stop"
    case traceRead = "trace_read"
    case targets
    case touchCapture = "touch_capture"
    case touchRead = "touch_read"
    case touchReplay = "touch_replay"
    case logs
    case clearLogs = "clear_logs"
    case unhideSymbols = "unhide_symbols"
    case prepareSwiftUISource = "prepare_swiftui_source"
    case prepareSwiftUIProject = "prepare_swiftui_project"
    case setXcodePath = "set_xcode_path"
    case launchXcode = "launch_xcode"
    case getLastError = "get_last_error"
    case events
    case clearEvents = "clear_events"
    case profileSnapshot = "profile_snapshot"
    case setRuntimeEnv = "set_runtime_env"
    case traceScope = "trace_scope"
    case compilerState = "compiler_state"
    case compilerInterception = "compiler_interception"
    case callOrder = "call_order"
    case instancesStart = "instances_start"
    case instancesRead = "instances_read"
    case instancesStop = "instances_stop"
    case testResults = "test_results"
    case clearTestResults = "clear_test_results"
    case reorderProject = "reorder_project"
    case xprobeSearch = "xprobe_search"
    case xprobeInspect = "xprobe_inspect"
    case eval
    case projects
    case projectAdd = "project_add"
    case projectRemove = "project_remove"
}

public struct ControlRequest: Codable, Sendable {
    public let id: String
    public let action: ControlAction
    public let files: [String]?
    public let path: String?
    public let filter: String?
    public let limit: Int?
    public let target: String?
    public let payload: String?
    public let since: Double?
    public let environment: [String: String?]?
    public let scope: String?
    public let name: String?
    public let enabled: Bool?
    public let objectID: Int?
    public let projectID: String?

    public init(
        id: String = UUID().uuidString,
        action: ControlAction,
        files: [String]? = nil,
        path: String? = nil,
        filter: String? = nil,
        limit: Int? = nil,
        target: String? = nil,
        payload: String? = nil,
        since: Double? = nil,
        environment: [String: String?]? = nil,
        scope: String? = nil,
        name: String? = nil,
        enabled: Bool? = nil,
        objectID: Int? = nil,
        projectID: String? = nil
    ) {
        self.id = id
        self.action = action
        self.files = files
        self.path = path
        self.filter = filter
        self.limit = limit
        self.target = target
        self.payload = payload
        self.since = since
        self.environment = environment
        self.scope = scope
        self.name = name
        self.enabled = enabled
        self.objectID = objectID
        self.projectID = projectID
    }
}

public struct BackendStatus: Codable, Sendable {
    public let name: String
    public let ready: Bool
    public let appConnected: Bool
    public let capabilities: [String]
    public let platform: String?
    public let arch: String?
    public let temporaryPath: String?
    public let detail: String?

    public init(
        name: String,
        ready: Bool,
        appConnected: Bool,
        capabilities: [String],
        platform: String? = nil,
        arch: String? = nil,
        temporaryPath: String? = nil,
        detail: String? = nil
    ) {
        self.name = name
        self.ready = ready
        self.appConnected = appConnected
        self.capabilities = capabilities
        self.platform = platform
        self.arch = arch
        self.temporaryPath = temporaryPath
        self.detail = detail
    }
}

public struct DaemonStatus: Codable, Sendable {
    public let version: String
    public let pid: Int32
    public let socketPath: String
    public let backend: BackendStatus

    public init(
        version: String,
        pid: Int32,
        socketPath: String,
        backend: BackendStatus
    ) {
        self.version = version
        self.pid = pid
        self.socketPath = socketPath
        self.backend = backend
    }
}

public enum DoctorCheckState: String, Codable, Sendable, Equatable {
    case pass
    case warning
    case fail
}

public struct DoctorCheck: Codable, Sendable {
    public let name: String
    public let state: DoctorCheckState
    public let message: String

    public init(
        name: String,
        state: DoctorCheckState,
        message: String
    ) {
        self.name = name
        self.state = state
        self.message = message
    }
}

public struct DoctorRuntime: Codable, Sendable {
    public let connected: Bool
    public let platform: String?
    public let arch: String?
    public let temporaryPath: String?

    public init(
        connected: Bool,
        platform: String? = nil,
        arch: String? = nil,
        temporaryPath: String? = nil
    ) {
        self.connected = connected
        self.platform = platform
        self.arch = arch
        self.temporaryPath = temporaryPath
    }
}

public struct DoctorReport: Codable, Sendable {
    public let ready: Bool
    public let checks: [DoctorCheck]
    public let runtime: DoctorRuntime?

    public init(
        ready: Bool,
        checks: [DoctorCheck],
        runtime: DoctorRuntime? = nil
    ) {
        self.ready = ready
        self.checks = checks
        self.runtime = runtime
    }
}

public struct ScreenshotResult: Codable, Sendable {
    public let path: String
    public let mimeType: String
    public let byteCount: Int

    public init(
        path: String,
        mimeType: String,
        byteCount: Int
    ) {
        self.path = path
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

public struct TraceEvent: Codable, Sendable {
    public let sequence: Int64
    public let timestamp: Double
    public let text: String
    public let indent: Int?

    public init(
        sequence: Int64,
        timestamp: Double,
        text: String,
        indent: Int? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.text = text
        self.indent = indent
    }
}

public struct TraceResult: Codable, Sendable {
    public let connected: Bool
    public let active: Bool
    public let filter: String?
    public let events: [TraceEvent]

    public init(
        connected: Bool,
        active: Bool,
        filter: String? = nil,
        events: [TraceEvent] = []
    ) {
        self.connected = connected
        self.active = active
        self.filter = filter
        self.events = events
    }
}

public struct RuntimeTarget: Codable, Sendable, Equatable {
    public let id: String
    public let platform: String?
    public let arch: String?
    public let temporaryPath: String?
    public let peerAddress: String?
    public let projectRoot: String?
    public let executable: String?
    public let isLocal: Bool
    public let connected: Bool

    public init(
        id: String,
        platform: String? = nil,
        arch: String? = nil,
        temporaryPath: String? = nil,
        peerAddress: String? = nil,
        projectRoot: String? = nil,
        executable: String? = nil,
        isLocal: Bool,
        connected: Bool
    ) {
        self.id = id
        self.platform = platform
        self.arch = arch
        self.temporaryPath = temporaryPath
        self.peerAddress = peerAddress
        self.projectRoot = projectRoot
        self.executable = executable
        self.isLocal = isLocal
        self.connected = connected
    }
}

public struct TargetsResult: Codable, Sendable {
    public let targets: [RuntimeTarget]

    public init(targets: [RuntimeTarget]) {
        self.targets = targets
    }
}


public struct ProjectSessionSummary: Codable, Sendable, Equatable {
    public let id: String
    public let root: String
    public let displayName: String
    public let watching: Bool
    public let pendingCount: Int
    public let targetIDs: [String]

    public init(
        id: String,
        root: String,
        displayName: String,
        watching: Bool,
        pendingCount: Int,
        targetIDs: [String] = []
    ) {
        self.id = id
        self.root = root
        self.displayName = displayName
        self.watching = watching
        self.pendingCount = pendingCount
        self.targetIDs = targetIDs
    }
}

public struct ProjectsResult: Codable, Sendable {
    public let projects: [ProjectSessionSummary]
    public let unmatchedTargets: [RuntimeTarget]

    public init(
        projects: [ProjectSessionSummary],
        unmatchedTargets: [RuntimeTarget] = []
    ) {
        self.projects = projects
        self.unmatchedTargets = unmatchedTargets
    }
}

public struct PendingChangesResult: Codable, Sendable {
    public let projectRoot: String?
    public let watching: Bool
    public let files: [String]

    public init(
        projectRoot: String?,
        watching: Bool,
        files: [String]
    ) {
        self.projectRoot = projectRoot
        self.watching = watching
        self.files = files
    }
}

public struct TouchResult: Codable, Sendable {
    public let target: String?
    public let events: [String]
    public let replayed: Int?

    public init(
        target: String?,
        events: [String] = [],
        replayed: Int? = nil
    ) {
        self.target = target
        self.events = events
        self.replayed = replayed
    }
}

public struct LogEntry: Codable, Sendable {
    public let timestamp: Double
    public let level: String
    public let message: String

    public init(
        timestamp: Double,
        level: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public struct LogsResult: Codable, Sendable {
    public let entries: [LogEntry]

    public init(entries: [LogEntry]) {
        self.entries = entries
    }
}

public struct CompilerStateResult: Codable, Sendable {
    public let xcodePath: String?
    public let frontendPath: String?
    public let patchedFrontendPath: String?
    public let intercepted: Bool
    public let commandSource: String
    public let note: String?

    public init(
        xcodePath: String?,
        frontendPath: String?,
        patchedFrontendPath: String?,
        intercepted: Bool,
        commandSource: String,
        note: String? = nil
    ) {
        self.xcodePath = xcodePath
        self.frontendPath = frontendPath
        self.patchedFrontendPath = patchedFrontendPath
        self.intercepted = intercepted
        self.commandSource = commandSource
        self.note = note
    }
}

public struct OperationResult: Codable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct LastErrorResult: Codable, Sendable {
    public let source: String?
    public let error: ControlError?

    public init(
        source: String? = nil,
        error: ControlError? = nil
    ) {
        self.source = source
        self.error = error
    }
}

public struct InjectionEvent: Codable, Sendable {
    public let sequence: Int64
    public let timestamp: Double
    public let phase: String
    public let source: String?
    public let target: String?
    public let message: String?
    public let compileMilliseconds: Double?
    public let linkMilliseconds: Double?

    public init(
        sequence: Int64,
        timestamp: Double,
        phase: String,
        source: String? = nil,
        target: String? = nil,
        message: String? = nil,
        compileMilliseconds: Double? = nil,
        linkMilliseconds: Double? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.phase = phase
        self.source = source
        self.target = target
        self.message = message
        self.compileMilliseconds = compileMilliseconds
        self.linkMilliseconds = linkMilliseconds
    }
}

public struct InjectionEventsResult: Codable, Sendable {
    public let events: [InjectionEvent]

    public init(events: [InjectionEvent]) {
        self.events = events
    }
}

public struct DiagnosticsResult: Codable, Sendable {
    public let generatedAt: Double
    public let status: BackendStatus
    public let targets: TargetsResult
    public let trace: TraceResult
    public let compilerState: CompilerStateResult
    public let doctor: DoctorReport
    public let logs: LogsResult
    public let events: InjectionEventsResult
    public let lastError: LastErrorResult

    public init(
        generatedAt: Double = Date.timeIntervalSinceReferenceDate,
        status: BackendStatus,
        targets: TargetsResult,
        trace: TraceResult,
        compilerState: CompilerStateResult,
        doctor: DoctorReport,
        logs: LogsResult,
        events: InjectionEventsResult,
        lastError: LastErrorResult
    ) {
        self.generatedAt = generatedAt
        self.status = status
        self.targets = targets
        self.trace = trace
        self.compilerState = compilerState
        self.doctor = doctor
        self.logs = logs
        self.events = events
        self.lastError = lastError
    }
}

public struct ProfileStat: Codable, Sendable {
    public let method: String
    public let elapsedSeconds: Double
    public let invocations: Int
    public let averageMilliseconds: Double

    public init(
        method: String,
        elapsedSeconds: Double,
        invocations: Int,
        averageMilliseconds: Double
    ) {
        self.method = method
        self.elapsedSeconds = elapsedSeconds
        self.invocations = invocations
        self.averageMilliseconds = averageMilliseconds
    }
}

public struct ProfileResult: Codable, Sendable {
    public let connected: Bool
    public let stats: [ProfileStat]

    public init(
        connected: Bool,
        stats: [ProfileStat]
    ) {
        self.connected = connected
        self.stats = stats
    }
}

public struct CallOrderResult: Codable, Sendable {
    public let signatures: [String]

    public init(signatures: [String]) {
        self.signatures = signatures
    }
}

public struct InstanceCount: Codable, Sendable {
    public let type: String
    public let count: Int

    public init(type: String, count: Int) {
        self.type = type
        self.count = count
    }
}

public struct InstanceCountsResult: Codable, Sendable {
    public let active: Bool
    public let counts: [InstanceCount]

    public init(
        active: Bool,
        counts: [InstanceCount]
    ) {
        self.active = active
        self.counts = counts
    }
}

public struct InjectedTestResult: Codable, Sendable {
    public let name: String
    public let passed: Bool
    public let failures: Int
    public let durationSeconds: Double?
    public let messages: [String]

    public init(
        name: String,
        passed: Bool,
        failures: Int,
        durationSeconds: Double? = nil,
        messages: [String] = []
    ) {
        self.name = name
        self.passed = passed
        self.failures = failures
        self.durationSeconds = durationSeconds
        self.messages = messages
    }
}

public struct TestResultsResult: Codable, Sendable {
    public let connected: Bool
    public let results: [InjectedTestResult]

    public init(
        connected: Bool,
        results: [InjectedTestResult]
    ) {
        self.connected = connected
        self.results = results
    }
}

public struct XprobeObject: Codable, Sendable, Equatable {
    public let id: Int
    public let path: String?
    public let className: String
    public let description: String

    public init(
        id: Int,
        path: String? = nil,
        className: String,
        description: String
    ) {
        self.id = id
        self.path = path
        self.className = className
        self.description = description
    }
}

public struct XprobeResult: Codable, Sendable {
    public let available: Bool
    public let objects: [XprobeObject]
    public let selected: XprobeObject?
    public let details: String?
    public let error: String?

    public init(
        available: Bool,
        objects: [XprobeObject] = [],
        selected: XprobeObject? = nil,
        details: String? = nil,
        error: String? = nil
    ) {
        self.available = available
        self.objects = objects
        self.selected = selected
        self.details = details
        self.error = error
    }
}

public struct EvalResult: Codable, Sendable {
    public let available: Bool
    public let objectID: Int
    public let succeeded: Bool
    public let error: String?

    public init(
        available: Bool,
        objectID: Int,
        succeeded: Bool,
        error: String? = nil
    ) {
        self.available = available
        self.objectID = objectID
        self.succeeded = succeeded
        self.error = error
    }
}

public struct InjectionResult: Codable, Sendable {
    public let file: String
    public let compiled: Bool
    public let injected: Bool
    public let compileMilliseconds: Double?
    public let linkMilliseconds: Double?
    public let message: String?

    public init(
        file: String,
        compiled: Bool,
        injected: Bool,
        compileMilliseconds: Double? = nil,
        linkMilliseconds: Double? = nil,
        message: String? = nil
    ) {
        self.file = file
        self.compiled = compiled
        self.injected = injected
        self.compileMilliseconds = compileMilliseconds
        self.linkMilliseconds = linkMilliseconds
        self.message = message
    }
}

public struct CompilerDiagnostic: Codable, Sendable {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let severity: String
    public let message: String

    public init(
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        severity: String,
        message: String
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }
}

public struct ControlError: Codable, Error, Sendable {
    public let code: String
    public let message: String
    public let diagnostics: [CompilerDiagnostic]?

    public init(
        code: String,
        message: String,
        diagnostics: [CompilerDiagnostic]? = nil
    ) {
        self.code = code
        self.message = message
        self.diagnostics = diagnostics
    }
}

public struct ControlResponse: Codable, Sendable {
    public let id: String?
    public let ok: Bool
    public let status: DaemonStatus?
    public let injections: [InjectionResult]?
    public let pendingChanges: PendingChangesResult?
    public let doctor: DoctorReport?
    public let diagnostics: DiagnosticsResult?
    public let screenshot: ScreenshotResult?
    public let trace: TraceResult?
    public let targets: TargetsResult?
    public let touch: TouchResult?
    public let logs: LogsResult?
    public let operation: OperationResult?
    public let lastError: LastErrorResult?
    public let events: InjectionEventsResult?
    public let profile: ProfileResult?
    public let compilerState: CompilerStateResult?
    public let callOrder: CallOrderResult?
    public let instances: InstanceCountsResult?
    public let tests: TestResultsResult?
    public let reorder: ProjectReorderPlan?
    public let xprobe: XprobeResult?
    public let eval: EvalResult?
    public let projects: ProjectsResult?
    public let error: ControlError?

    public init(
        id: String?,
        ok: Bool,
        status: DaemonStatus? = nil,
        injections: [InjectionResult]? = nil,
        pendingChanges: PendingChangesResult? = nil,
        doctor: DoctorReport? = nil,
        diagnostics: DiagnosticsResult? = nil,
        screenshot: ScreenshotResult? = nil,
        trace: TraceResult? = nil,
        targets: TargetsResult? = nil,
        touch: TouchResult? = nil,
        logs: LogsResult? = nil,
        operation: OperationResult? = nil,
        lastError: LastErrorResult? = nil,
        events: InjectionEventsResult? = nil,
        profile: ProfileResult? = nil,
        compilerState: CompilerStateResult? = nil,
        callOrder: CallOrderResult? = nil,
        instances: InstanceCountsResult? = nil,
        tests: TestResultsResult? = nil,
        reorder: ProjectReorderPlan? = nil,
        xprobe: XprobeResult? = nil,
        eval: EvalResult? = nil,
        projects: ProjectsResult? = nil,
        error: ControlError? = nil
    ) {
        self.id = id
        self.ok = ok
        self.status = status
        self.injections = injections
        self.pendingChanges = pendingChanges
        self.doctor = doctor
        self.diagnostics = diagnostics
        self.screenshot = screenshot
        self.trace = trace
        self.targets = targets
        self.touch = touch
        self.logs = logs
        self.operation = operation
        self.lastError = lastError
        self.events = events
        self.profile = profile
        self.compilerState = compilerState
        self.callOrder = callOrder
        self.instances = instances
        self.tests = tests
        self.reorder = reorder
        self.xprobe = xprobe
        self.eval = eval
        self.projects = projects
        self.error = error
    }

    public static func status(id: String, _ status: DaemonStatus) -> ControlResponse {
        ControlResponse(id: id, ok: true, status: status)
    }

    public static func injection(
        id: String,
        results: [InjectionResult],
        error: ControlError? = nil
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: error == nil,
            injections: results,
            error: error
        )
    }

    public static func pendingChanges(
        id: String,
        result: PendingChangesResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            pendingChanges: result
        )
    }

    public static func doctor(
        id: String,
        report: DoctorReport
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: report.ready,
            doctor: report,
            error: report.ready
                ? nil
                : ControlError(
                    code: "DOCTOR_NOT_READY",
                    message: "One or more required injection checks failed."
                )
        )
    }

    public static func diagnostics(
        id: String,
        result: DiagnosticsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            diagnostics: result
        )
    }

    public static func screenshot(
        id: String,
        result: ScreenshotResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            screenshot: result
        )
    }

    public static func trace(
        id: String,
        result: TraceResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            trace: result
        )
    }

    public static func targets(
        id: String,
        result: TargetsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            targets: result
        )
    }

    public static func touch(
        id: String,
        result: TouchResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            touch: result
        )
    }

    public static func logs(
        id: String,
        result: LogsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            logs: result
        )
    }

    public static func operation(
        id: String,
        result: OperationResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            operation: result
        )
    }

    public static func lastError(
        id: String,
        result: LastErrorResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            lastError: result
        )
    }

    public static func events(
        id: String,
        result: InjectionEventsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            events: result
        )
    }

    public static func profile(
        id: String,
        result: ProfileResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            profile: result
        )
    }

    public static func compilerState(
        id: String,
        result: CompilerStateResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            compilerState: result
        )
    }

    public static func callOrder(
        id: String,
        result: CallOrderResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            callOrder: result
        )
    }

    public static func instances(
        id: String,
        result: InstanceCountsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            instances: result
        )
    }

    public static func tests(
        id: String,
        result: TestResultsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            tests: result
        )
    }

    public static func reorder(
        id: String,
        result: ProjectReorderPlan
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            reorder: result
        )
    }

    public static func xprobe(
        id: String,
        result: XprobeResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: result.error == nil,
            xprobe: result,
            error: result.error.map {
                ControlError(
                    code: result.available
                        ? "XPROBE_FAILED"
                        : "XPROBE_UNAVAILABLE",
                    message: $0
                )
            }
        )
    }

    public static func eval(
        id: String,
        result: EvalResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: result.succeeded,
            eval: result,
            error: result.succeeded
                ? nil
                : ControlError(
                    code: result.available
                        ? "EVAL_FAILED"
                        : "XPROBE_UNAVAILABLE",
                    message: result.error
                        ?? "Eval failed."
                )
        )
    }

    public static func projects(
        id: String,
        result: ProjectsResult
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            projects: result
        )
    }

    public static func failure(
        id: String? = nil,
        code: String,
        message: String
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: false,
            error: ControlError(code: code, message: message)
        )
    }
}

public enum ControlCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()
}
