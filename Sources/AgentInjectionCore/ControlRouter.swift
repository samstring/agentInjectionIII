import Foundation

public final class ControlRouter {
    public static let daemonVersion = "0.1.0"

    private let socketPath: String
    private let backend: InjectionBackend

    public init(
        socketPath: String,
        backend: InjectionBackend
    ) {
        self.socketPath = socketPath
        self.backend = backend
    }

    public func handle(_ requestData: Data) -> Data {
        let response: ControlResponse

        do {
            let request = try ControlCodec.decoder.decode(
                ControlRequest.self,
                from: requestData
            )

            response = route(request)
        } catch {
            response = .failure(
                code: "INVALID_REQUEST",
                message: "Unable to decode request: \(error)"
            )
        }

        do {
            return try ControlCodec.encoder.encode(response)
        } catch {
            let fallback = """
            {"ok":false,"error":{"code":"ENCODING_ERROR","message":"Unable to encode response."}}
            """
            return Data(fallback.utf8)
        }
    }

    private func route(_ request: ControlRequest) -> ControlResponse {
        switch request.action {
        case .status:
            let status = DaemonStatus(
                version: Self.daemonVersion,
                pid: ProcessInfo.processInfo.processIdentifier,
                socketPath: socketPath,
                backend: backend.status()
            )
            return .status(id: request.id, status)

        case .pendingChanges:
            return .pendingChanges(
                id: request.id,
                result: backend.pendingChanges()
            )

        case .injectPending:
            let result = backend.injectPending(
                target: request.target
            )
            return .injection(
                id: request.id,
                results: result.results,
                error: result.error
            )

        case .inject:
            guard let files = request.files, !files.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_FILES",
                    message: "inject requires at least one source file."
                )
            }

            let result = backend.inject(
                files: files,
                target: request.target
            )
            return .injection(
                id: request.id,
                results: result.results,
                error: result.error
            )

        case .loadDylib:
            guard let path = request.path, !path.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_PATH",
                    message: "load_dylib requires a dylib path."
                )
            }

            let result = backend.loadDylib(
                path: path,
                target: request.target
            )
            return .injection(
                id: request.id,
                results: result.results,
                error: result.error
            )

        case .doctor:
            return .doctor(
                id: request.id,
                report: backend.doctor(path: request.path)
            )

        case .diagnostics:
            return .diagnostics(
                id: request.id,
                result: backend.diagnostics(
                    limit: request.limit
                )
            )

        case .screenshot:
            switch backend.screenshot(
                path: request.path,
                target: request.target
            ) {
            case .success(let result):
                return .screenshot(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .targets:
            return .targets(
                id: request.id,
                result: backend.targets()
            )

        case .touchCapture:
            switch backend.touchCapture(
                target: request.target
            ) {
            case .success(let result):
                return .touch(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .touchRead:
            switch backend.touchRead(
                target: request.target
            ) {
            case .success(let result):
                return .touch(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .touchReplay:
            guard let payload = request.payload,
                  !payload.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_PAYLOAD",
                    message: "touch_replay requires a JSON payload."
                )
            }

            switch backend.touchReplay(
                payload: payload,
                target: request.target
            ) {
            case .success(let result):
                return .touch(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .logs:
            return .logs(
                id: request.id,
                result: backend.logs(
                    since: request.since,
                    limit: request.limit
                )
            )

        case .clearLogs:
            return .logs(
                id: request.id,
                result: backend.clearLogs()
            )

        case .unhideSymbols:
            switch backend.unhideSymbols() {
            case .success(let result):
                return .operation(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .prepareSwiftUISource:
            guard let path = request.path,
                  !path.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_PATH",
                    message: "prepare_swiftui_source requires a Swift source path."
                )
            }

            switch backend.prepareSwiftUISource(
                path: path
            ) {
            case .success(let result):
                return .operation(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .prepareSwiftUIProject:
            switch backend.prepareSwiftUIProject() {
            case .success(let result):
                return .operation(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .setXcodePath:
            guard let path = request.path,
                  !path.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_PATH",
                    message: "set_xcode_path requires an Xcode.app path."
                )
            }

            switch backend.setXcodePath(
                path: path
            ) {
            case .success(let result):
                return .operation(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .launchXcode:
            switch backend.launchXcode() {
            case .success(let result):
                return .operation(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .getLastError:
            return .lastError(
                id: request.id,
                result: backend.lastError()
            )

        case .events:
            return .events(
                id: request.id,
                result: backend.events(
                    limit: request.limit
                )
            )

        case .clearEvents:
            return .events(
                id: request.id,
                result: backend.clearEvents()
            )

        case .setRuntimeEnv:
            guard let environment = request.environment,
                  !environment.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_ENVIRONMENT",
                    message: "set_runtime_env requires at least one INJECTION_* setting."
                )
            }

            switch backend.setRuntimeEnvironment(
                environment,
                target: request.target
            ) {
            case .success(let result):
                return .operation(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .compilerState:
            return .compilerState(
                id: request.id,
                result: backend.compilerState()
            )

        case .compilerInterception:
            guard let enabled = request.enabled else {
                return .failure(
                    id: request.id,
                    code: "MISSING_ENABLED",
                    message: "compiler_interception requires enabled=true or false."
                )
            }

            switch backend.setCompilerInterception(
                enabled: enabled
            ) {
            case .success(let result):
                return .compilerState(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .profileSnapshot:
            switch backend.profileSnapshot(
                limit: request.limit
            ) {
            case .success(let result):
                return .profile(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .traceStart:
            switch backend.traceStart(filter: request.filter) {
            case .success(let result):
                return .trace(id: request.id, result: result)
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .traceScope:
            guard let scope = request.scope,
                  !scope.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_SCOPE",
                    message: "trace_scope requires a scope."
                )
            }

            switch backend.traceScope(
                scope: scope,
                name: request.name,
                filter: request.filter
            ) {
            case .success(let result):
                return .trace(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .callOrder:
            switch backend.callOrder() {
            case .success(let result):
                return .callOrder(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .instancesStart:
            switch backend.instancesStart() {
            case .success(let result):
                return .instances(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .instancesRead:
            switch backend.instancesRead() {
            case .success(let result):
                return .instances(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .instancesStop:
            switch backend.instancesStop() {
            case .success(let result):
                return .instances(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .testResults:
            return .tests(
                id: request.id,
                result: backend.testResults(
                    limit: request.limit
                )
            )

        case .clearTestResults:
            return .tests(
                id: request.id,
                result: backend.clearTestResults()
            )

        case .reorderProject:
            switch backend.reorderProject(
                path: request.path,
                apply: request.enabled == true
            ) {
            case .success(let result):
                return .reorder(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .xprobeSearch:
            switch backend.xprobeSearch(
                pattern: request.filter
            ) {
            case .success(let result):
                return .xprobe(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .xprobeInspect:
            guard let objectID = request.objectID else {
                return .failure(
                    id: request.id,
                    code: "MISSING_OBJECT_ID",
                    message: "xprobe_inspect requires objectID."
                )
            }

            switch backend.xprobeInspect(
                objectID: objectID
            ) {
            case .success(let result):
                return .xprobe(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .eval:
            guard let objectID = request.objectID else {
                return .failure(
                    id: request.id,
                    code: "MISSING_OBJECT_ID",
                    message: "eval requires objectID."
                )
            }
            guard let code = request.payload,
                  !code.isEmpty else {
                return .failure(
                    id: request.id,
                    code: "MISSING_CODE",
                    message: "eval requires non-empty code."
                )
            }

            switch backend.eval(
                objectID: objectID,
                code: code
            ) {
            case .success(let result):
                return .eval(
                    id: request.id,
                    result: result
                )
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .traceStop:
            switch backend.traceStop() {
            case .success(let result):
                return .trace(id: request.id, result: result)
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }

        case .traceRead:
            switch backend.traceRead(limit: request.limit) {
            case .success(let result):
                return .trace(id: request.id, result: result)
            case .failure(let error):
                return .failure(
                    id: request.id,
                    code: error.code,
                    message: error.message
                )
            }
        }
    }
}
