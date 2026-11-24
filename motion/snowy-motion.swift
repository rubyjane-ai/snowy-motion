// snowy-motion — reads the MacBook's built-in motion sensor and sends tilt and shaking
// to Snowy over UDP (127.0.0.1:47391). Runs as root (a LaunchDaemon), because the sensor
// is only reachable through IOKit HID with administrator rights.
//
// Sensor access follows olvvier/apple-silicon-accelerometer (MIT, see
// LICENSE-apple-silicon-accelerometer): the accelerometer is the AppleSPUHIDDevice with
// usage page 0xFF00, usage 3; 22-byte reports carry x, y, z as little-endian Int32 at
// byte 6 in Q16 (1 g = 65536).
//
// Usage:  snowy-motion              run and stream (the daemon)
//         snowy-motion --calibrate  find which axis is "left–right" on this Mac (interactive)
//         snowy-motion --check      print live readings for 5 seconds
//
// Build:  swiftc -O -swift-version 5 snowy-motion.swift -o snowy-motion

import Foundation
import IOKit
import IOKit.hid

let udpPort: UInt16 = 47391
let supportDirectory = "/Library/Application Support/SnowyMotion"
let configPath = supportDirectory + "/axis.conf"

// MARK: - State (single-threaded: everything runs on the main run loop)

var lateralAxis = 1
var lateralSign: Float = 1
var lateralNeutral: Float = 0
var gravity = SIMD3<Float>(0, 0, 0)
var haveGravity = false
var shake: Float = 0
var shakeSide: Float = 0
var lastSampleTime: UInt64 = 0
var lastSendTime: UInt64 = 0
var collecting = false
var collected: [SIMD3<Float>] = []
var devices: [IOHIDDevice] = []
var sock: Int32 = -1
var destination = sockaddr_in()
var timebase = mach_timebase_info_data_t()

func seconds(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

func component(_ v: SIMD3<Float>, _ axis: Int) -> Float { axis == 0 ? v.x : (axis == 1 ? v.y : v.z) }

func length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }

// MARK: - Config

func loadConfig() -> Bool {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
    for part in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        let pair = part.split(separator: "=")
        guard pair.count == 2 else { continue }
        switch pair[0] {
        case "axis": lateralAxis = max(0, min(2, Int(pair[1]) ?? 1))
        case "sign": lateralSign = (Float(pair[1]) ?? 1) < 0 ? -1 : 1
        case "neutral": lateralNeutral = Float(pair[1]) ?? 0
        default: break
        }
    }
    return true
}

func saveConfig() throws {
    try FileManager.default.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
    let text = "axis=\(lateralAxis) sign=\(Int(lateralSign)) neutral=\(lateralNeutral)\n"
    try text.write(toFile: configPath, atomically: true, encoding: .utf8)
}

// MARK: - Signal processing

/// Sideways tilt as sin(angle), positive when the right side is lower.
func currentTilt() -> Float {
    let norm = length(gravity)
    guard norm > 0.3 else { return 0 }
    return max(-1, min(1, lateralSign * (component(gravity, lateralAxis) / norm - lateralNeutral)))
}

func process(_ sample: SIMD3<Float>) {
    let now = mach_absolute_time()
    let dt = lastSampleTime == 0 ? 0.001 : max(0.0001, min(0.1, seconds(now - lastSampleTime)))
    lastSampleTime = now
    if collecting { collected.append(sample) }
    if !haveGravity { gravity = sample; haveGravity = true }
    // Gravity: low-pass with a 0.25 s time constant. Shake: what remains, with a fast attack
    // and a ~0.35 s release so a single jolt lasts a few frames on screen.
    gravity += (sample - gravity) * Float(1 - exp(-dt / 0.25))
    let jolt = sample - gravity
    let strength = length(jolt)
    shake = max(strength, shake * Float(exp(-dt / 0.35)))
    if strength > 0.08 {
        shakeSide = max(-1, min(1, lateralSign * component(jolt, lateralAxis) / strength))
    }
    if seconds(now - lastSendTime) >= 1.0 / 60.0 {
        lastSendTime = now
        sendMotion([currentTilt(), shake, shakeSide, 0])
    }
}

// MARK: - UDP

func openSocket() {
    sock = socket(AF_INET, SOCK_DGRAM, 0)
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = udpPort.bigEndian
    destination.sin_addr.s_addr = inet_addr("127.0.0.1")
}

func sendMotion(_ values: [Float]) {
    guard sock >= 0 else { return }
    var packet = values
    var address = destination
    packet.withUnsafeMutableBytes { bytes in
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                _ = sendto(sock, bytes.baseAddress, bytes.count, 0, socketAddress,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - Sensor

let reportCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    guard length == 22 else { return }
    let raw = UnsafeRawPointer(report)
    let x = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 6, as: Int32.self))) / 65536
    let y = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 10, as: Int32.self))) / 65536
    let z = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 14, as: Int32.self))) / 65536
    process(SIMD3(x, y, z))
}

func intProperty(_ service: io_service_t, _ key: String) -> Int {
    guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return 0 }
    return value.intValue
}

func wakeSensorDrivers() {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS
    else { return }
    defer { IOObjectRelease(iterator) }
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
            IORegistryEntrySetCFProperty(service, key as CFString, NSNumber(value: Int32(value)))
        }
        IOObjectRelease(service)
    }
}

func openAccelerometer() -> Bool {
    wakeSensorDrivers()
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS
    else { return false }
    defer { IOObjectRelease(iterator) }
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        guard intProperty(service, "PrimaryUsagePage") == 0xFF00, intProperty(service, "PrimaryUsage") == 3,
              let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            fputs("snowy-motion: cannot open the motion sensor (IOReturn 0x\(String(UInt32(bitPattern: opened), radix: 16))). Run as root.\n", stderr)
            continue
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 4096, reportCallback, nil)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        devices.append(device)
    }
    return !devices.isEmpty
}

func runLoop(for duration: Double) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
}

func averageOf(_ samples: [SIMD3<Float>]) -> SIMD3<Float>? {
    guard !samples.isEmpty else { return nil }
    let total = samples.reduce(SIMD3<Float>(0, 0, 0), +)
    let mean = total / Float(samples.count)
    let norm = length(mean)
    return norm > 0.3 ? mean / norm : nil
}

func sample(seconds duration: Double) -> SIMD3<Float>? {
    collected.removeAll()
    collecting = true
    runLoop(for: duration)
    collecting = false
    return averageOf(collected)
}

// MARK: - Modes

func calibrate() -> Int32 {
    print("Tilt sensor calibration.\n")
    print("1) Put your Mac flat on the desk and press Enter.")
    _ = readLine()
    runLoop(for: 0.3)
    guard let flat = sample(seconds: 1.5) else {
        print("The sensor is not responding. Calibration failed.")
        return 1
    }
    print("2) Press Enter, then within 3 seconds LIFT THE LEFT EDGE of your Mac")
    print("   (so it tilts to the right) by about 20–30° and hold it there.")
    _ = readLine()
    for second in stride(from: 3, through: 1, by: -1) { print("   \(second)…"); runLoop(for: 1) }
    print("   Hold…")
    guard let tilted = sample(seconds: 1.5) else {
        print("The sensor is not responding. Calibration failed.")
        return 1
    }
    let delta = tilted - flat
    let magnitudes = [abs(delta.x), abs(delta.y), abs(delta.z)]
    guard let best = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] }), magnitudes[best] > 0.12 else {
        print("Hardly any tilt detected. Run the calibration again and tilt further.")
        return 1
    }
    lateralAxis = best
    lateralSign = component(delta, best) > 0 ? 1 : -1
    lateralNeutral = component(flat, best)
    do { try saveConfig() } catch {
        print("Could not save the calibration: \(error.localizedDescription)")
        return 1
    }
    print("\nDone: axis \(["X", "Y", "Z"][best]), sign \(Int(lateralSign)). You can put your Mac down.")
    return 0
}

func check() -> Int32 {
    _ = loadConfig()
    for _ in 0..<10 {
        runLoop(for: 0.5)
        print(String(format: "tilt %+.2f   shake %.2f g   side %+.2f", currentTilt(), shake, shakeSide))
    }
    return 0
}

// MARK: - Main

mach_timebase_info(&timebase)
openSocket()
guard openAccelerometer() else {
    fputs("snowy-motion: motion sensor not found on this Mac.\n", stderr)
    exit(2)
}
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--calibrate") { exit(calibrate()) }
if arguments.contains("--check") { exit(check()) }
if !loadConfig() {
    fputs("snowy-motion: no calibration yet (\(configPath)); using defaults. Run with --calibrate.\n", stderr)
}
CFRunLoopRun()
