import Foundation

/// AOA (Android Open Accessory) protocol constants.
///
/// The identification strings MUST match the `<usb-accessory>` filter in
/// AndroidClient/aoabench/src/main/res/xml/accessory_filter.xml — Android
/// matches on manufacturer + model to route the accessory to the bench app.
enum AOAConstants {
    static let googleVendorID: UInt16 = 0x18D1
    static let accessoryPID: UInt16 = 0x2D00        // accessory only
    static let accessoryAdbPID: UInt16 = 0x2D01     // accessory + adb

    // Vendor requests on the default control endpoint (AOA v1/v2).
    static let requestGetProtocol: UInt8 = 51
    static let requestSendString: UInt8 = 52
    static let requestStart: UInt8 = 53

    enum StringID: UInt16, CaseIterable {
        case manufacturer = 0
        case model = 1
        case description = 2
        case version = 3
        case uri = 4
        case serial = 5
    }

    static let manufacturer = "SideScreen"
    static let model = "AOABench"
    static let description = "SideScreen AOA throughput bench"
    static let version = "1"
    static let uri = "https://sidescreen.dev"
    static let serial = "aoatest"

    static func string(for id: StringID) -> String {
        switch id {
        case .manufacturer: return manufacturer
        case .model: return model
        case .description: return description
        case .version: return version
        case .uri: return uri
        case .serial: return serial
        }
    }

    // adb function interface signature (how we recognize an Android device
    // without touching it): vendor-specific class, subclass 0x42, protocol 1.
    static let adbInterfaceClass: UInt8 = 0xFF
    static let adbInterfaceSubclass: UInt8 = 0x42
    static let adbInterfaceProtocol: UInt8 = 0x01

    // Accessory bulk interface signature in accessory mode.
    static let accessoryInterfaceClass: UInt8 = 0xFF
    static let accessoryInterfaceSubclass: UInt8 = 0xFF
    static let accessoryInterfaceProtocol: UInt8 = 0x00
}

/// Wire format of the bench stream. All integers are little endian.
///
/// Downlink block (Mac → tablet):
///   magic "SSAB" | seq u64 | payloadLen u32 | flags u32 (bit0 = ping) |
///   checksum u64 (wrapping sum of payload u64 words) | sendNs u64 | payload
///
/// Uplink messages (tablet → Mac):
///   ACK  "SSAA" | lastSeq u64 | totalBytes u64 | checksumErrors u32   (1 Hz)
///   PONG "SSAP" | seq u64 | echoedSendNs u64                          (per ping)
enum BenchWire {
    static let blockMagic: UInt32 = 0x42415353      // "SSAB" little endian
    static let ackMagic: UInt32 = 0x41415353        // "SSAA"
    static let pongMagic: UInt32 = 0x50415353       // "SSAP"
    // 4 magic + 8 seq + 4 len + 4 flags + 8 checksum + 8 sendNs
    static let blockHeaderSize = 36
    static let ackSize = 24
    static let pongSize = 20
    static let flagPing: UInt32 = 1
    static let flagNoVerify: UInt32 = 2

    /// Wrapping 64-bit word sum over the payload. Chosen over CRC32 so the
    /// integrity check itself cannot become the bottleneck at multi-Gbps.
    static func checksum(_ data: UnsafeRawBufferPointer) -> UInt64 {
        var sum: UInt64 = 0
        let words = data.count / 8
        let wordBuf = data.bindMemory(to: UInt64.self)
        for i in 0..<words {
            sum = sum &+ wordBuf[i]
        }
        for i in (words * 8)..<data.count {
            sum = sum &+ UInt64(data[i])
        }
        return sum
    }
}
