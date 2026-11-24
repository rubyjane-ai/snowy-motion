import Darwin
import Foundation
import SnowCore

/// Receives laptop tilt and shaking from the optional snowy-motion helper, which reads the
/// built-in motion sensor and sends 16-byte UDP packets to 127.0.0.1 (four little-endian
/// Float32: tilt, shake, shakeSide, reserved). Without the helper nothing arrives and the
/// snow behaves as before. Polled once per frame; never blocks.
@MainActor
final class MotionReceiver {
    static let port: UInt16 = 47391
    private var socketFD: Int32 = -1
    private var latest = DeviceMotion.still
    private var lastPacket: TimeInterval = 0
    private var buffer = [Float](repeating: 0, count: 4)

    init() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = MotionReceiver.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); return }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        socketFD = fd
    }

    /// Drains waiting packets and returns the newest motion. Falls back to still when the
    /// helper has been silent for half a second (not installed, stopped, or Mac asleep).
    func poll() -> DeviceMotion {
        guard socketFD >= 0 else { return .still }
        let fd = socketFD
        while true {
            let received = buffer.withUnsafeMutableBytes { bytes in
                recv(fd, bytes.baseAddress, bytes.count, 0)
            }
            guard received >= 16 else { break }
            latest = DeviceMotion(tilt: buffer[0], shake: buffer[1], shakeSide: buffer[2])
            lastPacket = ProcessInfo.processInfo.systemUptime
        }
        if ProcessInfo.processInfo.systemUptime - lastPacket > 0.5 { latest = .still }
        return latest
    }
}
