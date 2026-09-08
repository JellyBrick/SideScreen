import Foundation
import IOKit

/// AOA (Android Open Accessory) protocol constants for the production app.
///
/// The identification strings MUST match the `<usb-accessory>` filter in
/// AndroidClient/app/src/main/res/xml/accessory_filter.xml — Android routes
/// the accessory to our client app by manufacturer + model.
enum AOAConstants {
    static let googleVendorID = 0x18D1
    static let accessoryPID = 0x2D00        // accessory only
    static let accessoryAdbPID = 0x2D01     // accessory + adb

    static let requestGetProtocol: UInt8 = 51
    static let requestSendString: UInt8 = 52
    static let requestStart: UInt8 = 53

    static let manufacturer = "SideScreen"
    static let model = "SideScreen"
    static let description = "SideScreen USB direct display link"
    static let version = "1"
    static let uri = "https://sidescreen.dev"

    /// (wIndex, value) pairs for SEND_STRING, in send order.
    static var identificationStrings: [(UInt16, String)] {
        [(0, manufacturer), (1, model), (2, description), (3, version), (4, uri)]
    }

    struct InterfaceSignature {
        let classCode: UInt8
        let subclass: UInt8
        let protocolCode: UInt8
    }

    static let adbInterface = InterfaceSignature(classCode: 0xFF, subclass: 0x42, protocolCode: 0x01)
    static let accessoryInterface = InterfaceSignature(classCode: 0xFF, subclass: 0xFF, protocolCode: 0x00)

    /// Transport preamble: guards against stale bulk data from a previous
    /// session. Mac→client "SSAC" + version + nonce(8); client replies
    /// "SSAR" + version + echoed nonce.
    static let preambleMagic: [UInt8] = [0x53, 0x53, 0x41, 0x43] // "SSAC"
    static let preambleReplyMagic: [UInt8] = [0x53, 0x53, 0x41, 0x52] // "SSAR"
    static let preambleVersion: UInt8 = 1
    static let preambleLength = 13
}

/// Registry-only USB helpers (never opens a device — cannot collide with adb
/// or other daemons). Production twin of the AOATest probe.
enum AOAUSB {
    struct Device {
        let service: io_service_t   // retained; release with IOObjectRelease
        let vendorID: Int
        let productID: Int
        let name: String
        let serial: String
        let speedRaw: Int
        let hasAdbInterface: Bool

        var isAccessory: Bool {
            vendorID == AOAConstants.googleVendorID &&
                (productID == AOAConstants.accessoryPID || productID == AOAConstants.accessoryAdbPID)
        }

        var isAndroidCandidate: Bool { hasAdbInterface && !isAccessory }

        var speedDescription: String {
            switch speedRaw {
            case 2: return "USB 2.0 (480 Mbps)"
            case 3: return "USB 5 Gbps"
            case 4: return "USB 10 Gbps"
            case 5: return "USB 20 Gbps"
            default: return "USB"
            }
        }
    }

    static func property<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? T
    }

    static func allDevices() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vid: Int = property(service, "idVendor") ?? 0
            let pid: Int = property(service, "idProduct") ?? 0
            var hasAdb = false
            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS {
                while case let child = IOIteratorNext(childIter), child != 0 {
                    defer { IOObjectRelease(child) }
                    let cls: Int = property(child, "bInterfaceClass") ?? -1
                    let sub: Int = property(child, "bInterfaceSubClass") ?? -1
                    let proto: Int = property(child, "bInterfaceProtocol") ?? -1
                    if cls == Int(AOAConstants.adbInterface.classCode),
                       sub == Int(AOAConstants.adbInterface.subclass),
                       proto == Int(AOAConstants.adbInterface.protocolCode) {
                        hasAdb = true
                    }
                }
                IOObjectRelease(childIter)
            }
            devices.append(Device(
                service: service,
                vendorID: vid,
                productID: pid,
                name: property(service, "USB Product Name") ?? "?",
                serial: property(service, "USB Serial Number") ?? "",
                speedRaw: property(service, "USBSpeed") ?? property(service, "Device Speed") ?? -1,
                hasAdbInterface: hasAdb))
        }
        return devices
    }

    static func release(_ devices: [Device]) {
        for device in devices {
            IOObjectRelease(device.service)
        }
    }

    /// Retained io_service_t of the child interface matching class/sub/proto.
    static func findInterfaceService(
        device: io_service_t,
        signature: AOAConstants.InterfaceSignature
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
            if cls == Int(signature.classCode), sub == Int(signature.subclass), proto == Int(signature.protocolCode) {
                return child
            }
            IOObjectRelease(child)
        }
        return nil
    }
}
