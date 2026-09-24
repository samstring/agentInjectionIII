import Foundation

public enum ControlAction: String, Codable, Sendable {
    case status
    case inject
    case loadDylib = "load_dylib"
    case doctor
}

public struct ControlRequest: Codable, Sendable {
    public let id: String
    public let action: ControlAction
    public let files: [String]?
    public let path: String?

    public init(
        id: String = UUID().uuidString,
        action: ControlAction,
        files: [String]? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.action = action
        self.files = files
        self.path = path
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

public enum DoctorCheckState: String, Codable, Sendable {
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

public struct InjectionResult: Codable, Sendable {
    public let file: String
    public let compiled: Bool
    public let injected: Bool
    public let message: String?

    public init(
        file: String,
        compiled: Bool,
        injected: Bool,
        message: String? = nil
    ) {
        self.file = file
        self.compiled = compiled
        self.injected = injected
        self.message = message
    }
}

public struct ControlError: Codable, Error, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlResponse: Codable, Sendable {
    public let id: String?
    public let ok: Bool
    public let status: DaemonStatus?
    public let injections: [InjectionResult]?
    public let doctor: DoctorReport?
    public let error: ControlError?

    public init(
        id: String?,
        ok: Bool,
        status: DaemonStatus? = nil,
        injections: [InjectionResult]? = nil,
        doctor: DoctorReport? = nil,
        error: ControlError? = nil
    ) {
        self.id = id
        self.ok = ok
        self.status = status
        self.injections = injections
        self.doctor = doctor
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
