import Foundation
import Darwin

/// InjectionNext-compatible device discovery responder.
///
/// Real-device InjectionNext clients broadcast a small UDP packet on the same
/// numeric port as the TCP injection server. The packet carries a hash derived
/// from the developer home path. When the hash matches, the Mac replies with
/// its hostname and the device connects back to TCP :8887.
public final class InjectionDeviceDiscovery {
    public let port: UInt16

    private let queue = DispatchQueue(
        label: "agentInjectionIII.device-discovery",
        qos: .utility
    )
    private let expectedHash: Int32
    private let logStore: AgentLogStore?
    private var socketFD: Int32 = -1

    public init(
        port: UInt16 = 8887,
        injectionKey: String = NSHomeDirectory(),
        logStore: AgentLogStore? = nil
    ) {
        self.port = port
        self.expectedHash = Self.multicastHash(
            injectionKey
        )
        self.logStore = logStore
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard socketFD < 0 else { return }

        let fd = Darwin.socket(
            AF_INET,
            SOCK_DGRAM,
            0
        )
        guard fd >= 0 else {
            throw ControlError(
                code: "DEVICE_DISCOVERY_SOCKET_FAILED",
                message: "UDP socket() failed: \(String(cString: strerror(errno)))"
            )
        }

        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size
        )
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(
            s_addr: UInt32(INADDR_ANY).bigEndian
        )

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size
                    )
                )
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            throw ControlError(
                code: "DEVICE_DISCOVERY_BIND_FAILED",
                message: "Unable to bind UDP 0.0.0.0:\(port): \(String(cString: strerror(errno)))"
            )
        }

        socketFD = fd
        logStore?.append(
            "Device discovery listener started on UDP 0.0.0.0:\(port)."
        )
        queue.async { [weak self] in
            self?.serve()
        }
    }

    public func stop() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func serve() {
        // struct multicast_socket_packet {
        //   int version, hash;
        //   char host[256];
        // };
        let packetLength =
            MemoryLayout<Int32>.size * 2 + 256

        var buffer = [UInt8](
            repeating: 0,
            count: packetLength
        )

        while socketFD >= 0 {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(
                MemoryLayout<sockaddr_storage>.size
            )

            let count = withUnsafeMutablePointer(
                to: &peer
            ) { peerPointer in
                peerPointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { sockaddrPointer in
                    buffer.withUnsafeMutableBytes {
                        Darwin.recvfrom(
                            socketFD,
                            $0.baseAddress,
                            $0.count,
                            0,
                            sockaddrPointer,
                            &peerLength
                        )
                    }
                }
            }

            if count < 0 {
                if errno == EINTR { continue }
                if socketFD < 0 { return }
                continue
            }

            guard count >= MemoryLayout<Int32>.size * 2 else {
                continue
            }

            let data = Data(buffer.prefix(count))
            let version = Self.readInt32(
                data,
                offset: 0
            )
            let hash = Self.readInt32(
                data,
                offset: MemoryLayout<Int32>.size
            )

            guard version == 1,
                  hash == expectedHash else {
                logStore?.append(
                    "Device discovery packet rejected (version=\(version), keyMatch=\(hash == expectedHash)).",
                    level: "detail"
                )
                continue
            }

            logStore?.append(
                "Device discovery packet matched; replying with host identity."
            )

            let response = Self.makePacket(
                version: 1,
                hash: expectedHash,
                hostname: Self.hostname()
            )

            _ = response.withUnsafeBytes { raw in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        Darwin.sendto(
                            socketFD,
                            raw.baseAddress,
                            raw.count,
                            0,
                            $0,
                            peerLength
                        )
                    }
                }
            }
        }
    }

    private static func multicastHash(
        _ key: String
    ) -> Int32 {
        var hash: Int32 = 0

        for (index, byte) in key.utf8.enumerated() {
            let multiplier = Int32(
                (index + 3) % 15
            )
            hash = hash &* 5
            hash = hash ^ (
                multiplier &* Int32(byte)
            )
        }

        return hash
    }

    private static func makePacket(
        version: Int32,
        hash: Int32,
        hostname: String
    ) -> Data {
        var result = Data()
        var version = version
        var hash = hash

        withUnsafeBytes(of: &version) {
            result.append(contentsOf: $0)
        }
        withUnsafeBytes(of: &hash) {
            result.append(contentsOf: $0)
        }

        var host = [UInt8](
            repeating: 0,
            count: 256
        )
        let bytes = Array(hostname.utf8.prefix(255))
        host.replaceSubrange(
            0..<bytes.count,
            with: bytes
        )
        result.append(contentsOf: host)

        return result
    }

    private static func readInt32(
        _ data: Data,
        offset: Int
    ) -> Int32 {
        guard data.count >= offset + 4 else {
            return 0
        }

        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(
                to: $0,
                from: offset..<(offset + 4)
            )
        }
        return value
    }

    private static func hostname() -> String {
        var buffer = [CChar](
            repeating: 0,
            count: 256
        )

        guard gethostname(
            &buffer,
            buffer.count
        ) == 0 else {
            return "localhost"
        }

        return String(cString: buffer)
    }
}
