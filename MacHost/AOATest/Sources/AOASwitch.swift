import Foundation
import IOUSBHost
import IOKit

enum SwitchError: Error, CustomStringConvertible {
    case deviceOpenFailed(underlying: Error)
    case protocolQueryFailed(underlying: Error)
    case protocolTooOld(version: UInt16)
    case stringRejected(id: AOAConstants.StringID, underlying: Error)
    case startRejected(underlying: Error)
    case reenumerationTimeout

    var description: String {
        switch self {
        case .deviceOpenFailed(let e):
            return "device open failed (exclusive access?): \(e.localizedDescription)"
        case .protocolQueryFailed(let e):
            return "GET_PROTOCOL failed: \(e.localizedDescription)"
        case .protocolTooOld(let v):
            return "AOA protocol \(v) < 2 — device does not support AOAv2"
        case .stringRejected(let id, let e):
            return "SEND_STRING \(id) rejected: \(e.localizedDescription)"
        case .startRejected(let e):
            return "START rejected: \(e.localizedDescription)"
        case .reenumerationTimeout:
            return "device did not re-enumerate as accessory within timeout"
        }
    }
}

enum AOASwitch {
    /// Send the AOA v2 switch sequence to a device already found in normal
    /// (adb) mode, then wait for it to re-enumerate with the accessory PID.
    ///
    /// GATE A datapoints this collects:
    /// 1. Whether the exclusive device-level open succeeds while the adb
    ///    server holds the adb interface (retry with --kill-adb if not).
    /// 2. START→accessory-visible timing. Android reverts to normal mode if
    ///    the HOST has not configured the accessory device within 10 seconds
    ///    of START (UsbDeviceManager enter-timeout) — measured on a Galaxy
    ///    Tab: the SS+→accessory re-enumeration can take >10s on the first
    ///    attempt and get reverted; immediate retries tend to be faster, so
    ///    --retry is on by default.
    static func performSwitch(serial: String?, killAdb: Bool, retries: Int = 2, timeoutSeconds: Double = 15.0) throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try performSwitchOnce(serial: serial, killAdb: killAdb, timeoutSeconds: timeoutSeconds)
                return
            } catch SwitchError.reenumerationTimeout where attempt <= retries {
                print("Attempt \(attempt) did not stick — retrying (link is often faster the second time)…")
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
    }

    private static func performSwitchOnce(serial: String?, killAdb: Bool, timeoutSeconds: Double) throws {
        let devices = USBProbe.allDevices()
        defer { USBProbe.release(devices) }

        if let existing = devices.first(where: { $0.isAccessory && (serial == nil || $0.serial == serial) }) {
            print("Already in accessory mode: \(existing.name) [\(existing.speed)]")
            return
        }

        guard let target = devices.first(where: { $0.isAndroidCandidate && (serial == nil || $0.serial == serial) }) else {
            print("No Android device (adb interface) found. Is USB debugging enabled?")
            throw SwitchError.reenumerationTimeout
        }

        print("Target: \(target.name) serial=\(target.serial) link=\(target.speed)")

        if killAdb {
            print("Stopping adb server for exclusive device access…")
            _ = runAdb(["kill-server"])
        }

        let opened: IOUSBHostDevice
        do {
            opened = try IOUSBHostDevice(__ioService: target.service, options: [], queue: nil, interestHandler: nil)
        } catch {
            if !killAdb {
                print("Device open failed with adb server running.")
                print("→ This is the GATE A datapoint: retry with --kill-adb.")
            }
            throw SwitchError.deviceOpenFailed(underlying: error)
        }
        print("Device opened (exclusive) — adb server running: \(USBProbe.isAdbServerRunning() ? "yes" : "no")")

        do {
            let version = try getProtocol(opened)
            print("AOA protocol version: \(version)")
            guard version >= 2 else {
                opened.destroy()
                throw SwitchError.protocolTooOld(version: version)
            }

            for id in AOAConstants.StringID.allCases {
                try sendString(opened, id: id, value: AOAConstants.string(for: id))
            }
            print("Identification strings sent")

            try start(opened)
            print("START sent — waiting for re-enumeration…")
        } catch let error as SwitchError {
            opened.destroy()
            throw error
        } catch {
            opened.destroy()
            throw error
        }
        // START makes the device drop off the bus; the user client dies with it.
        opened.destroy()

        let startWait = Date()
        let deadline = startWait.addingTimeInterval(timeoutSeconds)
        var accessory: ProbedDevice?
        var firstSeen: TimeInterval?
        var vanished = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let now = USBProbe.allDevices()
            if let found = now.first(where: { $0.isAccessory }) {
                let elapsed = Date().timeIntervalSince(startWait)
                if firstSeen == nil {
                    firstSeen = elapsed
                    print(String(format: "Accessory visible on the Mac after %.1fs", elapsed))
                    if elapsed > 9.0 {
                        print("⚠️ >10s: Android's accessory enter-timeout has likely fired — expect a revert.")
                    }
                }
                accessory = found
                USBProbe.release(now)
                // Hold on a moment to confirm it does not get reverted by
                // Android's 10s enter-timeout.
                Thread.sleep(forTimeInterval: 1.0)
                let confirm = USBProbe.allDevices()
                let still = confirm.first(where: { $0.isAccessory }) != nil
                USBProbe.release(confirm)
                if still { break }
                vanished = true
                accessory = nil
                print("Accessory appeared and was reverted (Android enter-timeout).")
                break
            }
            USBProbe.release(now)
        }

        if killAdb {
            print("Restarting adb server…")
            _ = runAdb(["start-server"])
        }

        guard let acc = accessory else {
            if !vanished {
                print(String(format: "No accessory PID within %.0fs — Android likely reverted before the Mac finished enumerating.", timeoutSeconds))
            }
            throw SwitchError.reenumerationTimeout
        }
        let mode = acc.productID == AOAConstants.accessoryAdbPID ? "accessory+adb (0x2D01)" : "accessory (0x2D00)"
        print("✅ Re-enumerated as \(mode)")
        print("   link: \(acc.speed)   ← compare with the pre-switch link speed!")
        for iface in acc.interfaceSummary {
            print("   iface: \(iface)")
        }
    }

    /// Reset the accessory device: this re-enumerates it back to normal mode
    /// on every device tested so far — the documented recovery primitive.
    static func resetAccessory() throws {
        let devices = USBProbe.allDevices()
        defer { USBProbe.release(devices) }
        guard let acc = devices.first(where: { $0.isAccessory }) else {
            print("No accessory-mode device found.")
            return
        }
        let dev = try IOUSBHostDevice(__ioService: acc.service, options: [], queue: nil, interestHandler: nil)
        print("Resetting \(acc.name)…")
        do {
            try dev.reset()
        } catch {
            // The reset tears down the user client underneath us; errors here
            // usually just mean the device already left the bus.
            print("reset returned: \(error.localizedDescription) (often benign)")
        }
        dev.destroy()
        print("Done — the device should re-enumerate in normal mode.")
    }

    private static func getProtocol(_ device: IOUSBHostDevice) throws -> UInt16 {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0xC0    // device-to-host | vendor | device
        request.bRequest = AOAConstants.requestGetProtocol
        request.wValue = 0
        request.wIndex = 0
        request.wLength = 2
        guard let data = NSMutableData(length: 2) else { fatalError("alloc") }
        var transferred = 0
        do {
            try device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 2.0)
        } catch {
            throw SwitchError.protocolQueryFailed(underlying: error)
        }
        guard transferred >= 2 else { throw SwitchError.protocolTooOld(version: 0) }
        let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private static func sendString(_ device: IOUSBHostDevice, id: AOAConstants.StringID, value: String) throws {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x40    // host-to-device | vendor | device
        request.bRequest = AOAConstants.requestSendString
        request.wValue = 0
        request.wIndex = id.rawValue
        var bytes = Array(value.utf8)
        bytes.append(0)                 // NUL terminated per AOA spec
        request.wLength = UInt16(bytes.count)
        let data = NSMutableData(bytes: &bytes, length: bytes.count)
        var transferred = 0
        do {
            try device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 2.0)
        } catch {
            throw SwitchError.stringRejected(id: id, underlying: error)
        }
    }

    private static func start(_ device: IOUSBHostDevice) throws {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x40
        request.bRequest = AOAConstants.requestStart
        request.wValue = 0
        request.wIndex = 0
        request.wLength = 0
        do {
            try device.__send(request, data: nil, bytesTransferred: nil, completionTimeout: 2.0)
        } catch {
            throw SwitchError.startRejected(underlying: error)
        }
    }

    @discardableResult
    private static func runAdb(_ args: [String]) -> Bool {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
        ]
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            print("adb binary not found — skipping \(args.joined(separator: " "))")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
