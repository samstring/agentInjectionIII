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
