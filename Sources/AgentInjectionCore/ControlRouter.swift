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

            let result = backend.inject(files: files)
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

            let result = backend.loadDylib(path: path)
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
        }
    }
}
