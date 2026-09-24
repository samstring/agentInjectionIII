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
    func inject(files: [String]) -> BackendInjectionResponse
    func loadDylib(path: String) -> BackendInjectionResponse
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

    public func inject(files: [String]) -> BackendInjectionResponse {
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

    public func loadDylib(path: String) -> BackendInjectionResponse {
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
