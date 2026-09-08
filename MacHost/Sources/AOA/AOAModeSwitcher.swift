import Foundation
import IOUSBHost
import IOKit

enum AOASwitchOutcome {
    case switched            // accessory PID visible and stable
    case alreadyAccessory
    case noCandidate
    case noAOASupport        // GET_PROTOCOL < 2 — never retry this device
    case failed(String)
}

/// Sends the AOA v2 switch sequence and waits for stable re-enumeration.
///
/// Measured behavior (Galaxy Tab, SS+): the exclusive device open succeeds
/// with the adb server running; re-enumeration takes ~0.4s when the client
/// app is foreground but can exceed Android's 10s accessory enter-timeout on
/// a first attempt, after which Android reverts — so callers retry.
enum AOAModeSwitcher {
    static func attemptSwitch(timeoutSeconds: Double = 15.0) -> AOASwitchOutcome {
        let devices = AOAUSB.allDevices()
        defer { AOAUSB.release(devices) }

        if devices.contains(where: { $0.isAccessory }) {
            return .alreadyAccessory
        }
        guard let target = devices.first(where: { $0.isAndroidCandidate }) else {
            return .noCandidate
        }

        let opened: IOUSBHostDevice
        do {
            opened = try IOUSBHostDevice(__ioService: target.service, options: [], queue: nil, interestHandler: nil)
        } catch {
            return .failed("device open: \(error.localizedDescription)")
        }

        do {
            let version = try getProtocol(opened)
            guard version >= 2 else {
                opened.destroy()
                return .noAOASupport
            }
            for (index, value) in AOAConstants.identificationStrings {
                try sendString(opened, index: index, value: value)
            }
            try start(opened)
        } catch {
            opened.destroy()
            return .failed("switch sequence: \(error.localizedDescription)")
        }
        // START drops the device off the bus; the user client dies with it.
        opened.destroy()

        // Wait for the accessory PID, then confirm it does not get reverted
        // by Android's 10s enter-timeout.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let now = AOAUSB.allDevices()
            let found = now.contains(where: { $0.isAccessory })
            AOAUSB.release(now)
            if found {
                Thread.sleep(forTimeInterval: 1.0)
                let confirm = AOAUSB.allDevices()
                let still = confirm.contains(where: { $0.isAccessory })
                AOAUSB.release(confirm)
                return still ? .switched : .failed("reverted (Android enter-timeout)")
            }
        }
        return .failed("no re-enumeration within \(Int(timeoutSeconds))s")
    }

    /// Reset an accessory-mode device back to normal mode (verified recovery
    /// primitive: normal re-enumeration + adb back within ~1s).
    static func resetAccessory() {
        let devices = AOAUSB.allDevices()
        defer { AOAUSB.release(devices) }
        guard let accessory = devices.first(where: { $0.isAccessory }) else { return }
        guard let dev = try? IOUSBHostDevice(__ioService: accessory.service, options: [], queue: nil, interestHandler: nil) else {
            return
        }
        try? dev.reset()
        dev.destroy()
    }

    private static func getProtocol(_ device: IOUSBHostDevice) throws -> UInt16 {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0xC0
        request.bRequest = AOAConstants.requestGetProtocol
        request.wLength = 2
        guard let data = NSMutableData(length: 2) else { return 0 }
        var transferred = 0
        try device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 2.0)
        guard transferred >= 2 else { return 0 }
        let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private static func sendString(_ device: IOUSBHostDevice, index: UInt16, value: String) throws {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x40
        request.bRequest = AOAConstants.requestSendString
        request.wIndex = index
        var bytes = Array(value.utf8)
        bytes.append(0)
        request.wLength = UInt16(bytes.count)
        let data = NSMutableData(bytes: &bytes, length: bytes.count)
        var transferred = 0
        try device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 2.0)
    }

    private static func start(_ device: IOUSBHostDevice) throws {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x40
        request.bRequest = AOAConstants.requestStart
        try device.__send(request, data: nil, bytesTransferred: nil, completionTimeout: 2.0)
    }
}
