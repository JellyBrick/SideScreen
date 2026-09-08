import Foundation
import IOKit

/// ByteChannel over the AOA bulk pipes. Receive side buffers incoming bulk
/// data and serves NWConnection-style (minimum, maximum) reads from it.
final class AOAChannel: ByteChannel {
    let kind: ChannelKind = .aoa
    let trust: ChannelTrust = .physicallySecured
    private let link: AOAAccessoryLink
    private let queue: DispatchQueue
    // Cursor-consumed receive buffer (compacts periodically) with a defensive
    // cap: the uplink is control-sized (touch/ping), so runaway growth means
    // a broken peer, not load.
    private var buffer = Data()
    private var bufferStart = 0
    private static let uplinkBufferCap = 1 << 20
    private struct PendingRead {
        let minimum: Int
        let maximum: Int
        let completion: (Data?, Bool, Error?) -> Void
    }

    private var pendingReads: [PendingRead] = []
    private var isClosed = false
    var onCancelled: (() -> Void)?

    init(link: AOAAccessoryLink, queue: DispatchQueue) {
        self.link = link
        self.queue = queue
        link.onData = { [weak self] data in
            guard let self = self else { return }
            self.buffer.append(data)
            self.serveReads()
        }
        link.onClosed = { [weak self] in
            self?.handleClosed()
        }
    }

    /// Feed bytes that arrived before the channel was created (preamble
    /// over-read). Called on `queue`.
    func seed(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        serveReads()
    }

    private var buffered: Int { buffer.count - bufferStart }

    private func serveReads() {
        if buffered > Self.uplinkBufferCap {
            debugLog("AOA: uplink buffer overflow (\(buffered)B) — dropping link")
            cancel()
            return
        }
        while let request = pendingReads.first {
            guard buffered >= request.minimum else { break }
            pendingReads.removeFirst()
            let take = min(buffered, request.maximum)
            let data = buffer.subdata(in: bufferStart..<(bufferStart + take))
            bufferStart += take
            request.completion(data, false, nil)
        }
        if bufferStart >= 4096 || (bufferStart > 0 && bufferStart == buffer.count) {
            buffer.removeSubrange(0..<bufferStart)
            bufferStart = 0
        }
    }

    private func handleClosed() {
        guard !isClosed else { return }
        isClosed = true
        for request in pendingReads {
            request.completion(nil, true, nil)
        }
        pendingReads.removeAll()
        onCancelled?()
    }

    func send(_ data: Data, completion: ((Error?) -> Void)?) {
        link.write(data, completion: completion)
    }

    func receive(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else {
                completion(nil, true, nil)
                return
            }
            self.pendingReads.append(PendingRead(minimum: minimum, maximum: maximum, completion: completion))
            self.serveReads()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.link.close()
            self.handleClosed()
        }
    }
}

/// Produces AOA channels: watches for Android devices (2s registry poll — no
/// device is ever opened while watching), switches them to accessory mode,
/// claims the bulk interface, runs the SSAC/SSAR preamble, and hands an
/// established channel to the streaming server.
///
/// Policy: never switch while a streaming session is active (the USB
/// re-enumeration would cut the adb link mid-stream); retry the switch once
/// on the observed Android enter-timeout revert; cool down after repeated
/// failures so a non-cooperating device is not hammered.
final class AOAChannelSource: ChannelSource {
    var onIncomingConnection: ((ByteChannel) -> Void)?
    var onChannelEstablished: ((ByteChannel) -> Void)?
    var onChannelClosed: ((ByteChannel) -> Void)?
    /// Injected: true while any client session is active (AOA or TCP).
    var isSessionActive: () -> Bool = { false }
    /// Status for the UI: "USB 10 Gbps" etc. once established.
    private(set) var linkDescription: String?

    private let callbackQueue: DispatchQueue
    private let usbQueue = DispatchQueue(label: "aoa.usb")
    private var pollTimer: DispatchSourceTimer?
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var link: AOAAccessoryLink?
    private var channel: AOAChannel?
    private var attemptInFlight = false
    private var cooldownUntil = Date.distantPast
    private var consecutiveFailures = 0
    private var skippedSerials: Set<String> = []   // devices without AOAv2

    init(callbackQueue: DispatchQueue) {
        self.callbackQueue = callbackQueue
    }

    func start() {
        // Event-driven attach detection: a first-match notification fires the
        // instant any USB device publishes (candidate or accessory re-enum) —
        // no 2s polling latency. The timer stays only as the retry engine for
        // cooldown expiry; its scan is O(1)-cheap while a session is active
        // (poll() bails before enumerating).
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, usbQueue)
        notifyPort = port
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"),
            { refcon, iterator in
                guard let refcon = refcon else { return }
                let source = Unmanaged<AOAChannelSource>.fromOpaque(refcon).takeUnretainedValue()
                // Drain to re-arm the notification, then evaluate.
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                source.poll()
            },
            refcon,
            &matchIterator)
        if result == KERN_SUCCESS {
            // Arming consumes the already-present devices; poll() below
            // evaluates them.
            while case let service = IOIteratorNext(matchIterator), service != 0 {
                IOObjectRelease(service)
            }
        } else {
            debugLog("AOA: matching notification failed (\(result)) — timer-only detection")
        }

        let timer = DispatchSource.makeTimerSource(queue: usbQueue)
        timer.schedule(deadline: .now() + 1, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        usbQueue.async { [weak self] in
            self?.teardownLink()
            // Leave the device in normal mode so plain adb keeps working
            // after the server stops.
            AOAModeSwitcher.resetAccessory()
        }
    }

    private func poll() {
        guard !attemptInFlight, channel == nil, Date() >= cooldownUntil else { return }

        let devices = AOAUSB.allDevices()
        defer { AOAUSB.release(devices) }

        if let accessory = devices.first(where: { $0.isAccessory }) {
            attemptInFlight = true
            claim(accessoryService: accessory.service, speed: accessory.speedDescription)
            return
        }

        guard let candidate = devices.first(where: { $0.isAndroidCandidate }) else { return }
        guard !skippedSerials.contains(candidate.serial) else { return }
        // Switching re-enumerates USB and would cut an active adb-based
        // stream — only convert while idle.
        guard !isSessionActive() else { return }

        attemptInFlight = true
        debugLog("AOA: switching \(candidate.name) to accessory mode…")
        let outcome = AOAModeSwitcher.attemptSwitch()
        switch outcome {
        case .switched, .alreadyAccessory:
            debugLog("AOA: accessory mode active")
            attemptInFlight = false
            // Claim on the next poll tick (registry entry needs a beat).
        case .noAOASupport:
            debugLog("AOA: device has no AOAv2 — disabling for this device")
            skippedSerials.insert(candidate.serial)
            attemptInFlight = false
        case .noCandidate:
            attemptInFlight = false
        case .failed(let reason):
            consecutiveFailures += 1
            let delay = min(60.0, 5.0 * Double(consecutiveFailures))
            cooldownUntil = Date().addingTimeInterval(delay)
            debugLog("AOA: switch failed (\(reason)) — retrying in \(Int(delay))s")
            attemptInFlight = false
        }
    }

    /// Claim the accessory interface and run the preamble. On usbQueue.
    private func claim(accessoryService: io_service_t, speed: String) {
        do {
            let link = try AOAAccessoryLink(accessoryDevice: accessoryService, speedDescription: speed, queue: usbQueue)
            self.link = link
            var preambleBuffer = Data()
            var established = false
            let nonce = (0..<8).map { _ in UInt8.random(in: 0...255) }

            link.onData = { [weak self] data in
                guard let self = self, !established else { return }
                preambleBuffer.append(data)
                guard preambleBuffer.count >= AOAConstants.preambleLength else { return }
                let bytes = [UInt8](preambleBuffer.prefix(AOAConstants.preambleLength))
                guard Array(bytes[0..<4]) == AOAConstants.preambleReplyMagic,
                      bytes[4] == AOAConstants.preambleVersion,
                      Array(bytes[5..<13]) == nonce else {
                    debugLog("AOA: bad preamble reply — dropping link")
                    self.teardownLink()
                    return
                }
                established = true
                let overRead = preambleBuffer.dropFirst(AOAConstants.preambleLength)
                self.finishEstablish(link: link, overRead: Data(overRead))
            }
            link.onClosed = { [weak self] in
                self?.usbQueue.async {
                    self?.teardownLink()
                }
            }
            link.startReading()

            var hello = Data(AOAConstants.preambleMagic)
            hello.append(AOAConstants.preambleVersion)
            hello.append(contentsOf: nonce)
            debugLog("AOA: link claimed (\(speed)) — sending preamble")
            // timeout 0: a NAKed bulk write completes the INSTANT the client
            // app opens the accessory and reads — pending indefinitely instead
            // of cycling teardown/re-claim (which wedged the kernel user
            // client and raced the client's own open/close cycle).
            link.write(hello, timeout: 0) { [weak self] error in
                if let error = error {
                    debugLog("AOA: preamble write failed: \(error.localizedDescription)")
                    self?.usbQueue.async { self?.teardownLink() }
                }
            }
            // Long-stop only: covers a truly dead client (app never opens).
            usbQueue.asyncAfter(deadline: .now() + 120.0) { [weak self, weak link] in
                guard let self = self, let staleLink = link, self.link === staleLink, self.channel == nil else { return }
                debugLog("AOA: no client answered for 120s — releasing link")
                self.teardownLink()
            }
        } catch {
            debugLog("AOA: claim failed: \(error.localizedDescription)")
            consecutiveFailures += 1
            // A failed claim means a zombie user client is squatting on the
            // interface — only a device reset clears it (see teardownLink).
            AOAModeSwitcher.resetAccessory()
            cooldownUntil = Date().addingTimeInterval(10.0)
            attemptInFlight = false
        }
    }

    private func finishEstablish(link: AOAAccessoryLink, overRead: Data) {
        let channel = AOAChannel(link: link, queue: usbQueue)
        channel.onCancelled = { [weak self] in
            self?.usbQueue.async {
                guard let self = self else { return }
                if self.channel === channel {
                    self.channel = nil
                    self.link = nil
                    self.linkDescription = nil
                    self.attemptInFlight = false
                }
                self.callbackQueue.async {
                    self.onChannelClosed?(channel)
                }
            }
        }
        self.channel = channel
        self.linkDescription = link.speedDescription
        self.consecutiveFailures = 0
        channel.seed(overRead)
        debugLog("AOA: preamble OK — channel established (\(link.speedDescription))")
        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.onIncomingConnection?(channel)
            self.onChannelEstablished?(channel)
        }
    }

    private func teardownLink() {
        link?.close()
        link = nil
        if let channel = channel {
            self.channel = nil
            callbackQueue.async { [weak self] in
                self?.onChannelClosed?(channel)
            }
        }
        linkDescription = nil
        attemptInFlight = false
        // A destroyed interface leaves a kernel-side zombie user client for
        // this device instance: every re-claim in this process fails with
        // "cannot create IOUSBHostInterface", and the gadget side may hold
        // stale bytes from the dead session. Resetting the device is the
        // verified recovery primitive: it re-enumerates in normal mode
        // (fresh io_service, empty gadget buffers, adb back within ~1s) and
        // the poll loop re-switches from a virgin state.
        AOAModeSwitcher.resetAccessory()
        cooldownUntil = Date().addingTimeInterval(Self.teardownCooldownSeconds)
    }

    private static let teardownCooldownSeconds = 5.0
}
