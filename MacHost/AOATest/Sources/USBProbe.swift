import Foundation
import IOKit

/// Registry-only device discovery: never opens a device, so it cannot collide
/// with adb or any other daemon holding user clients.
struct ProbedDevice {
    let service: io_service_t       // retained; caller releases via IOObjectRelease
    let vendorID: UInt16
    let productID: UInt16
    let name: String
    let serial: String
    let speed: String
    let hasAdbInterface: Bool
    let interfaceSummary: [String]  // "class/subclass/protocol name" per interface

    var isAccessory: Bool {
        vendorID == AOAConstants.googleVendorID &&
            (productID == AOAConstants.accessoryPID || productID == AOAConstants.accessoryAdbPID)
    }

    var isAndroidCandidate: Bool { hasAdbInterface && !isAccessory }
}

enum USBProbe {
    /// USB speed constants from IOUSBHostFamily (kUSBHostConnectionSpeed*).
    static func speedDescription(_ raw: Int) -> String {
        switch raw {
        case 0: return "Low (1.5 Mbps)"
        case 1: return "Full (12 Mbps)"
        case 2: return "High (480 Mbps)"
        case 3: return "SuperSpeed (5 Gbps)"
        case 4: return "SuperSpeed+ (10 Gbps)"
        case 5: return "SuperSpeed+ x2 (20 Gbps)"
        default: return "unknown (\(raw))"
        }
    }

    static func property<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? T
    }

    /// Enumerate every IOUSBHostDevice, reading identity and child interfaces
    /// from the IORegistry only.
    static func allDevices() -> [ProbedDevice] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [ProbedDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vid: Int = property(service, "idVendor") ?? 0
            let pid: Int = property(service, "idProduct") ?? 0
            let name: String = property(service, "USB Product Name") ?? "?"
            let serial: String = property(service, "USB Serial Number") ?? ""
            let speedRaw: Int = property(service, "USBSpeed") ?? property(service, "Device Speed") ?? -1

            var hasAdb = false
            var interfaces: [String] = []
            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS {
                while case let child = IOIteratorNext(childIter), child != 0 {
                    defer { IOObjectRelease(child) }
                    guard let cls: Int = property(child, "bInterfaceClass") else { continue }
                    let sub: Int = property(child, "bInterfaceSubClass") ?? 0
                    let proto: Int = property(child, "bInterfaceProtocol") ?? 0
                    let ifName: String = property(child, "USB Interface Name") ?? ""
                    interfaces.append(String(format: "%02X/%02X/%02X %@", cls, sub, proto, ifName))
                    if cls == Int(AOAConstants.adbInterfaceClass),
                       sub == Int(AOAConstants.adbInterfaceSubclass),
                       proto == Int(AOAConstants.adbInterfaceProtocol) {
                        hasAdb = true
                    }
                }
                IOObjectRelease(childIter)
            }

            devices.append(ProbedDevice(
                service: service,
                vendorID: UInt16(vid),
                productID: UInt16(pid),
                name: name,
                serial: serial,
                speed: speedDescription(speedRaw),
                hasAdbInterface: hasAdb,
                interfaceSummary: interfaces))
        }
        return devices
    }

    static func release(_ devices: [ProbedDevice]) {
        for device in devices {
            IOObjectRelease(device.service)
        }
    }

    /// Find the io_service_t of a child interface matching class/sub/protocol.
    /// The returned service is retained (caller releases).
    static func findInterfaceService(
        device: io_service_t,
        classCode: UInt8, subclass: UInt8, protocolCode: UInt8
    ) -> io_service_t? {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIter) }
        while case let child = IOIteratorNext(childIter), child != 0 {
            let cls: Int = property(child, "bInterfaceClass") ?? -1
            let sub: Int = property(child, "bInterfaceSubClass") ?? -1
            let proto: Int = property(child, "bInterfaceProtocol") ?? -1
            if cls == Int(classCode), sub == Int(subclass), proto == Int(protocolCode) {
                return child
            }
            IOObjectRelease(child)
        }
        return nil
    }

    static func printReport() {
        let devices = allDevices()
        defer { release(devices) }
        let adbServer = isAdbServerRunning()
        print("adb server running: \(adbServer ? "yes" : "no")")
        if devices.isEmpty {
            print("No USB devices found.")
            return
        }
        for dev in devices {
            let kind: String
            if dev.isAccessory {
                kind = dev.productID == AOAConstants.accessoryAdbPID ? "ACCESSORY+ADB" : "ACCESSORY"
            } else if dev.isAndroidCandidate {
                kind = "ANDROID (adb interface present)"
            } else {
                continue // only report Android-related devices
            }
            print(String(format: "%04X:%04X %@ [%@]", dev.vendorID, dev.productID, dev.name, kind))
            print("  serial: \(dev.serial)")
            print("  link:   \(dev.speed)")
            for iface in dev.interfaceSummary {
                print("  iface:  \(iface)")
            }
        }
        print("")
        print("Note: link speed matters twice — a device can enumerate SuperSpeed")
        print("normally but drop to High-Speed in accessory mode (f_accessory")
        print("without SS descriptors). Run probe again after `switch`.")
    }

    static func isAdbServerRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "adb"]
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
