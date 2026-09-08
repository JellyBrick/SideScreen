import Foundation
import IOUSBHost
import IOKit

/// Owns the claimed accessory interface and its bulk pipes.
///
/// Reads: a fixed pool of 16KB IN requests kept in flight (matches the
/// f_accessory TX granularity). Writes: one IORequest per send, split to
/// ≤256KB, with a ZLP appended whenever the total is a multiple of the max
/// packet size — otherwise the tail of a burst can sit in a half-filled 16KB
/// gadget-side URB until unrelated later traffic completes it.
final class AOAAccessoryLink {
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let queue: DispatchQueue
    let maxPacketSize: Int
    let speedDescription: String

    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    private var closed = false
    private static let maxWriteChunk = 256 * 1024
    private static let readSlotSize = 16384
    private static let readSlots = 2

    init(accessoryDevice: io_service_t, speedDescription: String, queue: DispatchQueue) throws {
        self.queue = queue
        self.speedDescription = speedDescription
        guard let ifaceService = AOAUSB.findInterfaceService(
            device: accessoryDevice, signature: AOAConstants.accessoryInterface) else {
            throw AOAError.interfaceNotFound
        }
        do {
            interface = try IOUSBHostInterface(__ioService: ifaceService, options: [], queue: queue, interestHandler: nil)
        } catch {
            IOObjectRelease(ifaceService)
            throw error
        }
        IOObjectRelease(ifaceService)

        let config = interface.configurationDescriptor
        let iface = interface.interfaceDescriptor
        var inAddr: UInt8 = 0
        var outAddr: UInt8 = 0
        var packet = 512
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(config, iface, current) {
            if endpoint.pointee.bmAttributes & 0x03 == 2 {
                let address = endpoint.pointee.bEndpointAddress
                if address & 0x80 != 0 {
                    inAddr = address
                } else {
                    outAddr = address
                }
                packet = Int(endpoint.pointee.wMaxPacketSize)
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard inAddr != 0, outAddr != 0 else {
            interface.destroy()
            throw AOAError.endpointsNotFound
        }
        maxPacketSize = packet
        do {
            inPipe = try interface.copyPipe(withAddress: Int(inAddr))
            outPipe = try interface.copyPipe(withAddress: Int(outAddr))
        } catch {
            interface.destroy()
            throw error
        }
    }

    enum AOAError: Error {
        case interfaceNotFound
        case endpointsNotFound
    }

    func startReading() {
        for _ in 0..<Self.readSlots {
            guard let buffer = NSMutableData(length: Self.readSlotSize) else { continue }
            queue.async { [weak self] in
                self?.enqueueRead(buffer)
            }
        }
    }

    private func enqueueRead(_ buffer: NSMutableData) {
        guard !closed else { return }
        do {
            try inPipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, bytesTransferred in
                guard let self = self, !self.closed else { return }
                if status == kIOReturnSuccess, bytesTransferred > 0 {
                    self.onData?(Data(bytes: buffer.bytes, count: bytesTransferred))
                    self.enqueueRead(buffer)
                } else if status == kIOReturnSuccess {
                    self.enqueueRead(buffer)
                } else {
                    // Aborted/device gone: one closure is enough.
                    self.markClosed()
                }
            }
        } catch {
            markClosed()
        }
    }

    /// Sends `data` on the OUT pipe. Serialize callers on `queue` (the send
    /// order defines the wire order). Completion fires after the final chunk
    /// (and trailing ZLP when needed) completes.
    func write(_ data: Data, timeout: TimeInterval = 10.0, completion: ((Error?) -> Void)?) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else {
                completion?(AOAError.interfaceNotFound)
                return
            }
            var offset = 0
            var lastError: Error?
            let group = DispatchGroup()
            while offset < data.count {
                let take = min(Self.maxWriteChunk, data.count - offset)
                let start = data.index(data.startIndex, offsetBy: offset)
                let end = data.index(start, offsetBy: take)
                let mutable: NSMutableData
                if take >= 512 {
                    // Zero-copy wrap of the payload window. Sound because
                    // video payloads are heap/CMBlockBuffer-backed Data
                    // (never inline-stored, always contiguous) and `data` is
                    // pinned by the completion below until the URB finishes.
                    // Previously subdata + NSMutableData(data:) copied every
                    // chunk twice (~75MB/s at 300Mbps on the USB queue).
                    mutable = data[start..<end].withUnsafeBytes { raw in
                        NSMutableData(
                            bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                            length: raw.count,
                            freeWhenDone: false)
                    }
                } else {
                    mutable = NSMutableData(data: data.subdata(in: start..<end))
                }
                group.enter()
                do {
                    try self.outPipe.enqueueIORequest(with: mutable, completionTimeout: timeout) { status, _ in
                        // CRITICAL: pin both objects until the URB completes.
                        // Without this the DMA reads recycled memory — on
                        // screen: the first chunks of every frame decode fine
                        // and the rest is macroblock garbage.
                        withExtendedLifetime(mutable) {}
                        withExtendedLifetime(data) {}
                        if status != kIOReturnSuccess {
                            lastError = NSError(domain: "AOA", code: Int(status))
                        }
                        group.leave()
                    }
                } catch {
                    lastError = error
                    group.leave()
                    break
                }
                offset += take
            }
            // ZLP only when the transfer ends on a packet boundary MID-URB:
            // a 16KB-aligned total fills gadget URBs exactly (no completion
            // needed), and a non-aligned tail is a natural short packet.
            if data.count % self.maxPacketSize == 0 && data.count % Self.readSlotSize != 0 {
                group.enter()
                do {
                    // ZLP: force a short-packet completion on the gadget side.
                    try self.outPipe.enqueueIORequest(with: nil, completionTimeout: 10.0) { _, _ in
                        group.leave()
                    }
                } catch {
                    group.leave()
                }
            }
            group.notify(queue: self.queue) {
                if lastError != nil && !self.closed {
                    self.markClosed()
                }
                completion?(lastError)
            }
        }
    }

    private func markClosed() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }

    /// MUST be called on `queue`. Runs inline: deferring the abort with an
    /// async hop let a stale link's teardown cancel the NEXT claim's requests
    /// on the same endpoints (generations overlapped and the host went deaf
    /// to the client's preamble reply).
    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        closed = true
        try? inPipe.__abort(with: .synchronous)
        try? outPipe.__abort(with: .synchronous)
        interface.destroy()
    }
}
