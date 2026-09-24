import Foundation

public struct BackendInjectionResponse: Sendable {
    public let results: [InjectionResult]
    public let error: ControlError?

    public init(results: [InjectionResult], error: ControlError? = nil) {
        self.results = results
        self.error = error
    }
}

public protocol InjectionBackend: AnyObject {
    var name: String { get }
    func status() -> BackendStatus
    func targets() -> TargetsResult
    func inject(files: [String], target: String?) -> BackendInjectionResponse
    func loadDylib(path: String, target: String?) -> BackendInjectionResponse
    func doctor(path: String?) -> DoctorReport
    func screenshot(path: String?, target: String?) -> Result<ScreenshotResult, ControlError>
    func touchCapture(target: String?) -> Result<TouchResult, ControlError>
    func touchRead(target: String?) -> Result<TouchResult, ControlError>
    func touchReplay(payload: String, target: String?) -> Result<TouchResult, ControlError>
    func logs(since: Double?, limit: Int?) -> LogsResult
    func clearLogs() -> LogsResult
    func unhideSymbols() -> Result<OperationResult, ControlError>
    func prepareSwiftUISource(path: String) -> Result<OperationResult, ControlError>
    func prepareSwiftUIProject() -> Result<OperationResult, ControlError>
    func setXcodePath(path: String) -> Result<OperationResult, ControlError>
    func launchXcode() -> Result<OperationResult, ControlError>
    func lastError() -> LastErrorResult
    func events(limit: Int?) -> InjectionEventsResult
    func clearEvents() -> InjectionEventsResult
    func profileSnapshot(limit: Int?) -> Result<ProfileResult, ControlError>
    func setRuntimeEnvironment(
        _ values: [String: String?],
        target: String?
    ) -> Result<OperationResult, ControlError>
    func traceStart(filter: String?) -> Result<TraceResult, ControlError>
    func traceScope(
        scope: String,
        name: String?,
        filter: String?
    ) -> Result<TraceResult, ControlError>
    func traceStop() -> Result<TraceResult, ControlError>
    func traceRead(limit: Int?) -> Result<TraceResult, ControlError>
}

/// Phase-1 backend.
///
/// This deliberately validates the control path without claiming that code
/// injection is already wired. Phase 2 will replace this implementation with
/// an InjectionNext-backed engine.
public final class ScaffoldInjectionBackend: InjectionBackend {
    public let name = "scaffold"
    private let projectRoot: String?

    public init(projectRoot: String? = nil) {
        self.projectRoot = projectRoot
    }

    public func status() -> BackendStatus {
        BackendStatus(
            name: name,
            ready: false,
            appConnected: false,
            capabilities: [
                "status",
                "inject-request-validation"
            ],
            detail: "Control plane is running; InjectionNext backend is not connected yet."
        )
    }

    public func targets() -> TargetsResult {
        TargetsResult(targets: [])
    }

    public func inject(
        files: [String],
        target: String?
    ) -> BackendInjectionResponse {
        let normalized = files.map { normalize(path: $0) }
        let results = normalized.map { file in
            InjectionResult(
                file: file,
                compiled: false,
                injected: false,
                message: "Injection backend is not connected yet."
            )
        }

        return BackendInjectionResponse(
            results: results,
            error: ControlError(
                code: "BACKEND_NOT_READY",
                message: "Injection engine is not connected yet."
            )
        )
    }

    public func loadDylib(
        path: String,
        target: String?
    ) -> BackendInjectionResponse {
        let normalized = normalize(path: path)
        return BackendInjectionResponse(
            results: [
                InjectionResult(
                    file: normalized,
                    compiled: true,
                    injected: false,
                    message: "Runtime bridge is not connected yet."
                )
            ],
            error: ControlError(
                code: "RUNTIME_NOT_READY",
                message: "Injection runtime bridge is not connected yet."
            )
        )
    }

    public func doctor(path: String?) -> DoctorReport {
        DoctorReport(
            ready: false,
            checks: [
                DoctorCheck(
                    name: "backend",
                    state: .fail,
                    message: "Scaffold backend has no injection engine."
                )
            ]
        )
    }

    public func screenshot(
        path: String?,
        target: String?
    ) -> Result<ScreenshotResult, ControlError> {
        .failure(
            ControlError(
                code: "RUNTIME_NOT_READY",
                message: "Scaffold backend has no connected app runtime."
            )
        )
    }

    public func touchCapture(
        target: String?
    ) -> Result<TouchResult, ControlError> {
        .failure(
            ControlError(
                code: "RUNTIME_NOT_READY",
                message: "Scaffold backend has no touch-capable runtime."
            )
        )
    }

    public func touchRead(
        target: String?
    ) -> Result<TouchResult, ControlError> {
        .failure(
            ControlError(
                code: "RUNTIME_NOT_READY",
                message: "Scaffold backend has no touch-capable runtime."
            )
        )
    }

    public func touchReplay(
        payload: String,
        target: String?
    ) -> Result<TouchResult, ControlError> {
        .failure(
            ControlError(
                code: "RUNTIME_NOT_READY",
                message: "Scaffold backend has no touch-capable runtime."
            )
        )
    }

    public func logs(
        since: Double?,
        limit: Int?
    ) -> LogsResult {
        LogsResult(entries: [])
    }

    public func clearLogs() -> LogsResult {
        LogsResult(entries: [])
    }

    public func unhideSymbols()
        -> Result<OperationResult, ControlError> {
        .failure(
            ControlError(
                code: "UNHIDE_NOT_READY",
                message: "Scaffold backend cannot unhide symbols."
            )
        )
    }

    public func prepareSwiftUISource(
        path: String
    ) -> Result<OperationResult, ControlError> {
        .failure(
            ControlError(
                code: "SWIFTUI_PREPARE_NOT_READY",
                message: "Scaffold backend cannot prepare SwiftUI sources."
            )
        )
    }

    public func prepareSwiftUIProject()
        -> Result<OperationResult, ControlError> {
        .failure(
            ControlError(
                code: "SWIFTUI_PREPARE_NOT_READY",
                message: "Scaffold backend cannot prepare a SwiftUI project."
            )
        )
    }

    public func setXcodePath(
        path: String
    ) -> Result<OperationResult, ControlError> {
        .failure(
            ControlError(
                code: "XCODE_NOT_READY",
                message: "Scaffold backend cannot configure Xcode."
            )
        )
    }

    public func launchXcode()
        -> Result<OperationResult, ControlError> {
        .failure(
            ControlError(
                code: "XCODE_NOT_READY",
                message: "Scaffold backend cannot launch Xcode."
            )
        )
    }

    public func lastError() -> LastErrorResult {
        LastErrorResult()
    }

    public func events(
        limit: Int?
    ) -> InjectionEventsResult {
        InjectionEventsResult(events: [])
    }

    public func clearEvents()
        -> InjectionEventsResult {
        InjectionEventsResult(events: [])
    }

    public func profileSnapshot(
        limit: Int?
    ) -> Result<ProfileResult, ControlError> {
        .failure(
            ControlError(
                code: "PROFILE_NOT_READY",
                message: "Scaffold backend has no profiling bridge."
            )
        )
    }

    public func setRuntimeEnvironment(
        _ values: [String: String?],
        target: String?
    ) -> Result<OperationResult, ControlError> {
        .failure(
            ControlError(
                code: "RUNTIME_NOT_READY",
                message: "Scaffold backend has no runtime environment channel."
            )
        )
    }

    public func traceStart(
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        .failure(
            ControlError(
                code: "TRACE_BRIDGE_NOT_READY",
                message: "Scaffold backend has no trace bridge."
            )
        )
    }

    public func traceScope(
        scope: String,
        name: String?,
        filter: String?
    ) -> Result<TraceResult, ControlError> {
        .failure(
            ControlError(
                code: "TRACE_BRIDGE_NOT_READY",
                message: "Scaffold backend has no scoped tracing bridge."
            )
        )
    }

    public func traceStop()
        -> Result<TraceResult, ControlError> {
        .failure(
            ControlError(
                code: "TRACE_BRIDGE_NOT_READY",
                message: "Scaffold backend has no trace bridge."
            )
        )
    }

    public func traceRead(
        limit: Int?
    ) -> Result<TraceResult, ControlError> {
        .failure(
            ControlError(
                code: "TRACE_BRIDGE_NOT_READY",
                message: "Scaffold backend has no trace bridge."
            )
        )
    }

    private func normalize(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
                .standardizedFileURL
                .path
        }

        let base = projectRoot
            ?? FileManager.default.currentDirectoryPath

        return URL(fileURLWithPath: base)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }
}
