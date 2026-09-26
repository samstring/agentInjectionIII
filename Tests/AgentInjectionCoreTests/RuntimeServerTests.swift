import XCTest
import Foundation
import Darwin
@testable import AgentInjectionCore

final class RuntimeServerTests: XCTestCase {
    func testInjectionNextHandshakeAndLoadDylib() throws {
        let port: UInt16 = 18887
        let runtime = InjectionNextRuntimeServer(port: port)
        try runtime.start()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentInjectionIII-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let inputDylib = tempDirectory.appendingPathComponent("input.dylib")
        try Data("fake dylib".utf8).write(to: inputDylib)

        let clientFinished = expectation(description: "fake runtime completed")
        let clientQueue = DispatchQueue(
            label: "agentInjectionIII.fake-runtime"
        )

        clientQueue.async {
            defer { clientFinished.fulfill() }

            do {
                let fd = try Self.connect(port: port)
                defer { Darwin.close(fd) }

                try Self.writeInt(4001, fd: fd)
                try Self.writeString(NSHomeDirectory(), fd: fd)

                XCTAssertEqual(try Self.readInt(fd: fd), 3)
                XCTAssertFalse(try Self.readString(fd: fd).isEmpty)

                try Self.writeInt(0, fd: fd)
                try Self.writeString("iPhoneSimulator", fd: fd)
                try Self.writeString("arm64", fd: fd)

                try Self.writeInt(3, fd: fd)
                try Self.writeString(
                    tempDirectory.path + "/",
                    fd: fd
                )

                try Self.writeInt(5, fd: fd)
                try Self.writeString(
                    "/tmp/AgentInjectionProject",
                    fd: fd
                )

                try Self.writeInt(8, fd: fd)
                try Self.writeString(
                    "/tmp/AgentInjectionProject/TestApp",
                    fd: fd
                )

                XCTAssertEqual(try Self.readInt(fd: fd), 1)
                let copiedDylib = try Self.readString(fd: fd)
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: copiedDylib
                    )
                )
                XCTAssertTrue(
                    URL(fileURLWithPath: copiedDylib)
                        .lastPathComponent
                        .hasPrefix("eval_injection_"),
                    copiedDylib
                )

                try Self.writeInt(1, fd: fd)
            } catch {
                XCTFail("fake runtime failed: \(error)")
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let status = runtime.status()
            if status.connected,
               status.platform != nil,
               status.arch != nil,
               status.temporaryPath != nil {
                break
            }
            usleep(10_000)
        }

        let readyStatus = runtime.status()
        XCTAssertTrue(readyStatus.connected)
        XCTAssertEqual(
            readyStatus.platform,
            "iPhoneSimulator"
        )
        XCTAssertEqual(
            readyStatus.arch,
            "arm64"
        )
        XCTAssertNotNil(
            readyStatus.temporaryPath
        )
        XCTAssertEqual(
            readyStatus.projectRoot,
            "/tmp/AgentInjectionProject"
        )
        XCTAssertEqual(
            readyStatus.executable,
            "/tmp/AgentInjectionProject/TestApp"
        )
        XCTAssertEqual(
            runtime.targets().first?.projectRoot,
            "/tmp/AgentInjectionProject"
        )

        let result = runtime.loadDylib(path: inputDylib.path)

        XCTAssertTrue(result.compiled)
        XCTAssertTrue(result.injected)

        wait(for: [clientFinished], timeout: 3)
    }

    private static func connect(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: "RuntimeServerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "socket failed"]
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(
            s_addr: inet_addr("127.0.0.1")
        )

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.connect(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            throw NSError(
                domain: "RuntimeServerTests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "connect failed: \(String(cString: strerror(errno)))"
                ]
            )
        }

        return fd
    }

    private static func writeInt(
        _ value: Int32,
        fd: Int32
    ) throws {
        var value = value
        let data = Data(
            bytes: &value,
            count: MemoryLayout<Int32>.size
        )
        try writeAll(data, fd: fd)
    }

    private static func readInt(fd: Int32) throws -> Int32 {
        let data = try readExactly(
            MemoryLayout<Int32>.size,
            fd: fd
        )

        var value: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(
                &value,
                base,
                MemoryLayout<Int32>.size
            )
        }
        return value
    }

    private static func writeString(
        _ value: String,
        fd: Int32
    ) throws {
        let data = Data(value.utf8)
        try writeInt(Int32(data.count), fd: fd)
        try writeAll(data, fd: fd)
    }

    private static func readString(fd: Int32) throws -> String {
        let count = try readInt(fd: fd)
        let data = try readExactly(Int(count), fd: fd)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "RuntimeServerTests",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "invalid utf8"
                ]
            )
        }
        return value
    }

    private static func readExactly(
        _ count: Int,
        fd: Int32
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0

        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }

            while offset < count {
                let readCount = Darwin.read(
                    fd,
                    base.advanced(by: offset),
                    count - offset
                )

                if readCount <= 0 {
                    throw NSError(
                        domain: "RuntimeServerTests",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey: "read failed"
                        ]
                    )
                }

                offset += readCount
            }
        }

        return data
    }

    private static func writeAll(
        _ data: Data,
        fd: Int32
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0

            while offset < raw.count {
                let written = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset
                )

                if written <= 0 {
                    throw NSError(
                        domain: "RuntimeServerTests",
                        code: 5,
                        userInfo: [
                            NSLocalizedDescriptionKey: "write failed"
                        ]
                    )
                }

                offset += written
            }
        }
    }
}
