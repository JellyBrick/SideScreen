import Foundation
import IOUSBHost
import IOKit

struct BenchConfig {
    var seconds: Int = 30
    var chunkKB: Int = 16          // payload size per block; header adds 32B
    var inflight: Int = 4
    var verify: Bool = true
    var pingIntervalMs: Int = 100
}

/// Shared stats/protocol logic for both AOA and TCP transports.
final class BenchSession {
    let config: BenchConfig
    private let startTime = Date()
    private var sequence: UInt64 = 0
    private var completedBytes: UInt64 = 0
    private var ackedBytes: UInt64 = 0
    private var lastAckSeq: UInt64 = 0
    private var remoteChecksumErrors: UInt32 = 0
    private var rttsMs: [Double] = []
    private var ioErrors = 0
    private var lastPingNs: UInt64 = 0
    private var windowBytes: UInt64 = 0
    private var lastReport = Date()
    private var uplinkParseBuffer = Data()

    init(config: BenchConfig) {
        self.config = config
    }

    var payloadSize: Int { config.chunkKB * 1024 }
    var blockSize: Int { BenchWire.blockHeaderSize + payloadSize }

    /// Fill `buffer` (blockSize bytes) with the next block. Returns its seq.
    /// Total block length is header(32) + N*1024 payload — deliberately never a
    /// multiple of 512/1024, so bulk transfers always end in a short packet
    /// and no ZLP handling is needed in the bench.
    func fillNextBlock(_ buffer: NSMutableData) -> UInt64 {
        let seq = sequence
        sequence += 1
        let nowNs = DispatchTime.now().uptimeNanoseconds
        var isPing = false
        if nowNs - lastPingNs > UInt64(config.pingIntervalMs) * 1_000_000 {
            isPing = true
            lastPingNs = nowNs
        }

        let raw = buffer.mutableBytes
        // Payload: repeat the sequence number — cheap and position-sensitive.
        let payload = raw.advanced(by: BenchWire.blockHeaderSize)
        let words = payload.assumingMemoryBound(to: UInt64.self)
        let pattern = seq &* 0x9E3779B97F4A7C15 &+ 0x1234567890ABCDEF
        for i in 0..<(payloadSize / 8) {
            words[i] = pattern &+ UInt64(i)
        }

        let checksum: UInt64
        if config.verify {
            checksum = BenchWire.checksum(UnsafeRawBufferPointer(start: payload, count: payloadSize))
        } else {
            checksum = 0
        }

        var offset = 0
        func put<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { src in
                raw.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            offset += MemoryLayout<T>.size
        }
        put(BenchWire.blockMagic)
        put(seq)
        put(UInt32(payloadSize))
        put((isPing ? BenchWire.flagPing : 0) | (config.verify ? 0 : BenchWire.flagNoVerify))
        put(checksum)
        put(nowNs)
        return seq
    }

    func recordCompletion(bytes: Int) {
        completedBytes += UInt64(bytes)
        windowBytes += UInt64(bytes)
    }

    func recordError() {
        ioErrors += 1
    }

    /// Feed uplink bytes; parses ACK/PONG messages (fixed sizes, magic-framed).
    func consumeUplink(_ data: Data) {
        uplinkParseBuffer.append(data)
        while true {
            guard uplinkParseBuffer.count >= 4 else { return }
            let magic = uplinkParseBuffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if magic == BenchWire.ackMagic {
                guard uplinkParseBuffer.count >= BenchWire.ackSize else { return }
                uplinkParseBuffer.withUnsafeBytes { buf in
                    lastAckSeq = buf.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
                    ackedBytes = buf.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
                    remoteChecksumErrors = buf.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
                }
                uplinkParseBuffer.removeFirst(BenchWire.ackSize)
            } else if magic == BenchWire.pongMagic {
                guard uplinkParseBuffer.count >= BenchWire.pongSize else { return }
                let sendNs = uplinkParseBuffer.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
                }
                let rtt = Double(DispatchTime.now().uptimeNanoseconds - sendNs) / 1_000_000.0
                rttsMs.append(rtt)
                uplinkParseBuffer.removeFirst(BenchWire.pongSize)
            } else {
                // Resync: drop one byte and retry (should not happen on a
                // healthy stream — count it as an error).
                ioErrors += 1
                uplinkParseBuffer.removeFirst(1)
            }
        }
    }

    func maybeReport() {
        let now = Date()
        let interval = now.timeIntervalSince(lastReport)
        guard interval >= 1.0 else { return }
        let mbps = Double(windowBytes) * 8.0 / interval / 1_000_000.0
        let rttPart: String
        if let last = rttsMs.last {
            rttPart = String(format: "rtt %.2fms", last)
        } else {
            rttPart = "rtt –"
        }
        print(String(format: "%5.0fs  %8.1f Mbps  acked seq %llu  remote-cksum-err %u  %@  ioErr %d",
                     now.timeIntervalSince(startTime), mbps, lastAckSeq, remoteChecksumErrors, rttPart, ioErrors))
        windowBytes = 0
        lastReport = now
    }

    func printSummary() {
        let elapsed = Date().timeIntervalSince(startTime)
        let mbps = Double(completedBytes) * 8.0 / elapsed / 1_000_000.0
        let ackedMbps = Double(ackedBytes) * 8.0 / elapsed / 1_000_000.0
        print("")
        print("===== summary =====")
        print(String(format: "duration:        %.1f s", elapsed))
        print(String(format: "sent (local):    %.1f MB, %.1f Mbps", Double(completedBytes) / 1e6, mbps))
        print(String(format: "acked (remote):  %.1f MB, %.1f Mbps  ← authoritative", Double(ackedBytes) / 1e6, ackedMbps))
        print("remote checksum errors: \(remoteChecksumErrors)")
        print("local io/parse errors:  \(ioErrors)")
        if !rttsMs.isEmpty {
            let sorted = rttsMs.sorted()
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            print(String(format: "rtt under load: p50 %.2f  p95 %.2f  p99 %.2f ms  (n=%d)",
                         pct(0.5), pct(0.95), pct(0.99), sorted.count))
        }
        print("")
        print("GATE B (SuperSpeed): acked ≥ 800 Mbps, rtt p99 ≤ 5 ms, checksum errors 0")
        print("GATE C (High-Speed): acked ≥ 250 Mbps AND jitter better than the --tcp baseline")
    }
}

enum AOABenchRunner {
    static func run(config: BenchConfig) throws {
        let devices = USBProbe.allDevices()
        guard let acc = devices.first(where: { $0.isAccessory }) else {
            USBProbe.release(devices)
            print("No accessory-mode device. Run `AOATest switch` first.")
            return
        }
        print("Accessory: \(acc.name) [\(acc.speed)] pid=0x\(String(acc.productID, radix: 16))")

        guard let ifaceService = USBProbe.findInterfaceService(
            device: acc.service,
            classCode: AOAConstants.accessoryInterfaceClass,
            subclass: AOAConstants.accessoryInterfaceSubclass,
            protocolCode: AOAConstants.accessoryInterfaceProtocol) else {
            USBProbe.release(devices)
            print("Accessory interface (FF/FF/00) not found in registry.")
            return
        }

        let ioQueue = DispatchQueue(label: "aoabench.io")
        let interface = try IOUSBHostInterface(__ioService: ifaceService, options: [], queue: ioQueue, interestHandler: nil)
        IOObjectRelease(ifaceService)
        USBProbe.release(devices)
        defer { interface.destroy() }

        let (inAddress, outAddress, maxPacket) = try findBulkEndpoints(interface)
        print("bulk IN 0x\(String(inAddress, radix: 16)), OUT 0x\(String(outAddress, radix: 16)), maxPacket \(maxPacket) (\(maxPacket >= 1024 ? "SuperSpeed" : "High-Speed") link)")

        let inPipe = try interface.copyPipe(withAddress: Int(inAddress))
        let outPipe = try interface.copyPipe(withAddress: Int(outAddress))

        let session = BenchSession(config: config)
        var running = true

        // Uplink: 2 outstanding 16KB reads. f_accessory completes each host IN
        // with at most one gadget-side write; 16KB covers the largest message.
        func enqueueRead(_ buffer: NSMutableData) {
            do {
                try inPipe.enqueueIORequest(with: buffer, completionTimeout: 0) { status, bytesTransferred in
                    if status == kIOReturnSuccess && bytesTransferred > 0 {
                        session.consumeUplink(Data(bytes: buffer.bytes, count: bytesTransferred))
                    } else if status != kIOReturnSuccess && running {
                        session.recordError()
                    }
                    if running { enqueueRead(buffer) }
                }
            } catch {
                if running {
                    session.recordError()
                }
            }
        }
        for _ in 0..<2 {
            guard let buf = NSMutableData(length: 16384) else { fatalError("alloc") }
            ioQueue.async { enqueueRead(buf) }
        }

        // Downlink: `inflight` outstanding block writes; each completion
        // refills its slot and re-enqueues, preserving pipe FIFO order.
        func enqueueWrite(_ buffer: NSMutableData) {
            _ = session.fillNextBlock(buffer)
            do {
                // 10s timeout: a silent bulk stall (observed once ~8s into a
                // soak) must surface as an error so recovery can run instead
                // of wedging every in-flight slot forever.
                try outPipe.enqueueIORequest(with: buffer, completionTimeout: 10.0) { status, bytesTransferred in
                    if status == kIOReturnSuccess {
                        session.recordCompletion(bytes: bytesTransferred)
                    } else if running {
                        // Most likely a stall; clearing on other errors is
                        // harmless (CLEAR_FEATURE HALT + data-toggle reset).
                        session.recordError()
                        try? outPipe.clearStall()
                    }
                    session.maybeReport()
                    if running { enqueueWrite(buffer) }
                }
            } catch {
                if running {
                    session.recordError()
                }
            }
        }
        for _ in 0..<config.inflight {
            guard let buf = NSMutableData(length: session.blockSize) else { fatalError("alloc") }
            ioQueue.async { enqueueWrite(buf) }
        }

        print("Running for \(config.seconds)s: chunk \(config.chunkKB)KB, inflight \(config.inflight), verify \(config.verify)")
        Thread.sleep(forTimeInterval: TimeInterval(config.seconds))
        running = false
        ioQueue.sync { }
        try? inPipe.__abort(with: .synchronous)
        try? outPipe.__abort(with: .synchronous)
        Thread.sleep(forTimeInterval: 0.2)
        session.printSummary()
    }

    private static func findBulkEndpoints(_ interface: IOUSBHostInterface) throws -> (UInt8, UInt8, Int) {
        let config = interface.configurationDescriptor
        let iface = interface.interfaceDescriptor
        var inAddr: UInt8 = 0
        var outAddr: UInt8 = 0
        var maxPacket = 0
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let ep = IOUSBGetNextEndpointDescriptor(config, iface, current) {
            let attributes = ep.pointee.bmAttributes & 0x03
            if attributes == 2 { // bulk
                let address = ep.pointee.bEndpointAddress
                if address & 0x80 != 0 {
                    inAddr = address
                } else {
                    outAddr = address
                }
                maxPacket = Int(ep.pointee.wMaxPacketSize)
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard inAddr != 0, outAddr != 0 else {
            throw SwitchError.reenumerationTimeout
        }
        return (inAddr, outAddr, maxPacket)
    }
}
