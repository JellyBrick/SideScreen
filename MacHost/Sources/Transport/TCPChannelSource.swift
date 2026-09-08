import Foundation
import Network
import os

private extension NWEndpoint {
    var isLoopback: Bool {
        switch self {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let v4): return v4.isLoopback
            case .ipv6(let v6): return v6.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}

/// TCP transport: owns the NWListener plus everything that is specific to
/// reaching the Mac over a socket — the loopback (USB via adb reverse) trust
/// shortcut, the SSWA wireless token handshake, and the SSPC code-pairing
/// exchange (issue #35). Channels handed to `onChannelEstablished` have
/// cleared all of it.
final class TCPChannelSource: ChannelSource {
    private let port: UInt16
    private let queue: DispatchQueue
    private var listener: NWListener?

    var onIncomingConnection: ((ByteChannel) -> Void)?
    var onChannelEstablished: ((ByteChannel) -> Void)?
    var onChannelClosed: ((ByteChannel) -> Void)?

    // Wireless auth: when non-nil, non-loopback connections must present this
    // 32-byte token before being allowed to proceed. nil means wireless mode
    // is inactive — non-loopback connections are rejected immediately.
    var expectedAuthToken: Data?
    var onWirelessClientPaired: ((String) -> Void)?

    // Code pairing (issue #35): when non-nil, a pre-auth "SSPC" request
    // carrying this one-time code is answered with the real auth token, and
    // the client reconnects through the normal SSWA handshake. Only honored
    // while wireless mode is active (expectedAuthToken != nil).
    //
    // The code is written from the main thread (rotation) and read on the
    // network queue (validation), so state lives behind a lock — and
    // validate-and-consume is a single critical section, so a code can never
    // be redeemed twice and pipelined guesses can never exceed the attempt
    // budget before the invalidation lands.
    private struct PairingState {
        var code: String?
        var failedAttempts = 0
    }

    private let pairingStateLock = OSAllocatedUnfairLock(initialState: PairingState())
    private static let maxPairingAttempts = 5

    var expectedPairingCode: String? {
        get { pairingStateLock.withLock { $0.code } }
        set {
            pairingStateLock.withLock { state in
                state.code = newValue
                state.failedAttempts = 0
            }
        }
    }

    var pairingMacName: String = "Mac"
    /// Fired with the device name after a code was accepted and the token
    /// issued. The code is already consumed (nil); the owner should install a
    /// fresh one.
    var onPairingSuccess: ((String) -> Void)?
    /// Fired when the attempt budget is exhausted. The code is already
    /// invalidated (nil); the owner should install a fresh one.
    var onPairingCodeExhausted: (() -> Void)?

    init(port: UInt16, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            // Optimize TCP for low-latency streaming
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true  // Disable Nagle's algorithm
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }

            listener?.stateUpdateHandler = { [port] state in
                switch state {
                case .ready:
                    debugLog("TCP Server listening on port \(port)")
                case .failed(let error):
                    debugLog("Server failed: \(error)")
                default:
                    break
                }
            }

            listener?.start(queue: queue)
        } catch {
            debugLog("Failed to start server: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ newConnection: NWConnection) {
        debugLog("New connection incoming...")

        let kind: ChannelKind = newConnection.endpoint.isLoopback ? .tcpLoopback : .tcpLan
        let channel = NWConnectionChannel(connection: newConnection, kind: kind)
        onIncomingConnection?(channel)

        newConnection.stateUpdateHandler = { [weak self] state in
            debugLog("Connection state: \(state)")
            switch state {
            case .ready:
                self?.vet(channel)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
                self?.onChannelClosed?(channel)
            case .cancelled:
                debugLog("Connection cancelled")
                self?.onChannelClosed?(channel)
            default:
                break
            }
        }

        newConnection.start(queue: queue)
    }

    private func vet(_ channel: NWConnectionChannel) {
        if channel.kind == .tcpLoopback {
            debugLog("Client connected via loopback (USB) — skipping auth")
            onChannelEstablished?(channel)
            return
        }
        guard let expected = expectedAuthToken else {
            debugLog("Rejecting non-loopback client: wireless mode not active")
            channel.cancel()
            return
        }
        debugLog("Client connected via LAN — running auth handshake")
        runAuthHandshake(channel: channel, expectedToken: expected)
    }

    private func runAuthHandshake(channel: NWConnectionChannel, expectedToken: Data) {
        // Read fixed prefix [magic 4][token 32][name_len 1] = 37 bytes.
        channel.receive(minimum: HandshakeCodec.fixedPrefixLen,
                        maximum: HandshakeCodec.fixedPrefixLen) { [weak self] prefixData, _, error in
            guard let self = self else { return }
            if let error = error {
                debugLog("Auth read error: \(error)")
                channel.cancel()
                return
            }
            guard let prefix = prefixData, prefix.count == HandshakeCodec.fixedPrefixLen else {
                self.sendAuthResponse(channel, status: .invalidMagic, thenClose: true)
                return
            }
            let prefixBytes = Array(prefix)
            if Array(prefixBytes[0..<4]) == HandshakeCodec.pairingRequestMagic {
                self.runPairingExchange(channel: channel, prefix: prefix)
                return
            }
            guard Array(prefixBytes[0..<4]) == HandshakeCodec.requestMagic else {
                self.sendAuthResponse(channel, status: .invalidMagic, thenClose: true)
                return
            }
            self.receiveNameSuffix(on: channel, prefix: prefix, onInvalid: {
                self.sendAuthResponse(channel, status: .invalidName, thenClose: true)
            }) { full in
                do {
                    let parsed = try HandshakeCodec.parseRequest(full)
                    if WirelessAuth.validate(parsed.token, expected: expectedToken) {
                        debugLog("Wireless auth OK — device: \(parsed.deviceName)")
                        self.sendAuthResponse(channel, status: .ok, thenClose: false)
                        self.onWirelessClientPaired?(parsed.deviceName)
                        self.onChannelEstablished?(channel)
                    } else {
                        debugLog("Wireless auth rejected: token mismatch")
                        self.sendAuthResponse(channel, status: .invalidToken, thenClose: true)
                    }
                } catch HandshakeError.invalidMagic {
                    self.sendAuthResponse(channel, status: .invalidMagic, thenClose: true)
                } catch HandshakeError.invalidName {
                    self.sendAuthResponse(channel, status: .invalidName, thenClose: true)
                } catch {
                    self.sendAuthResponse(channel, status: .invalidMagic, thenClose: true)
                }
            }
        }
    }

    /// Reads the variable `[name N]` tail shared by SSWA and SSPC requests and
    /// hands back the full request bytes. `onInvalid` fires for a bad name
    /// length or a short read; read errors cancel the connection.
    private func receiveNameSuffix(
        on channel: NWConnectionChannel,
        prefix: Data,
        onInvalid: @escaping () -> Void,
        completion: @escaping (Data) -> Void
    ) {
        let nameLen = Int(Array(prefix)[36])
        guard (1...64).contains(nameLen) else {
            onInvalid()
            return
        }
        channel.receive(minimum: nameLen, maximum: nameLen) { nameData, _, error in
            if let error = error {
                debugLog("Handshake name read error: \(error)")
                channel.cancel()
                return
            }
            guard let nameData = nameData, nameData.count == nameLen else {
                onInvalid()
                return
            }
            completion(prefix + nameData)
        }
    }

    /// Handles a pre-auth "SSPC" code-pairing request (issue #35). On a valid
    /// one-time code, answers with the real 32-byte token + Mac name and closes;
    /// the client then reconnects through the normal SSWA handshake.
    private func runPairingExchange(channel: NWConnectionChannel, prefix: Data) {
        receiveNameSuffix(on: channel, prefix: prefix, onInvalid: { [weak self] in
            self?.sendPairingResponse(channel, status: .invalidCode)
        }) { [weak self] full in
            guard let self = self else { return }
            do {
                let parsed = try HandshakeCodec.parsePairingRequest(full)
                switch self.consumePairingCode(candidate: parsed.code) {
                case .issued(let token):
                    debugLog("Pairing code accepted — issuing token to \(parsed.deviceName)")
                    self.sendPairingResponse(channel, status: .ok, token: token)
                    self.onPairingSuccess?(parsed.deviceName)
                case .rejected:
                    debugLog("Pairing code rejected")
                    self.sendPairingResponse(channel, status: .invalidCode)
                case .exhausted:
                    debugLog("Pairing code rejected — attempt budget exhausted, invalidating code")
                    self.sendPairingResponse(channel, status: .invalidCode)
                    self.onPairingCodeExhausted?()
                }
            } catch {
                // Malformed requests carry no code guess, so they don't touch
                // the attempt budget.
                debugLog("Malformed pairing request: \(error)")
                self.sendPairingResponse(channel, status: .invalidCode)
            }
        }
    }

    private enum PairingOutcome {
        case issued(Data)
        case rejected
        case exhausted
    }

    /// Single critical section for validate-and-consume: a correct guess nils
    /// the code before the token leaves the lock, and the attempt counter is
    /// bumped under the same lock — so neither double redemption nor
    /// budget-overrun is possible however requests are pipelined.
    private func consumePairingCode(candidate: String) -> PairingOutcome {
        pairingStateLock.withLock { state in
            guard let expected = state.code,
                  let token = self.expectedAuthToken,
                  PairingCode.validate(candidate, expected: expected) else {
                guard state.code != nil else { return .rejected }
                state.failedAttempts += 1
                if state.failedAttempts >= Self.maxPairingAttempts {
                    state.code = nil
                    state.failedAttempts = 0
                    return .exhausted
                }
                return .rejected
            }
            state.code = nil
            state.failedAttempts = 0
            return .issued(token)
        }
    }

    private func sendPairingResponse(_ channel: NWConnectionChannel, status: PairingStatus, token: Data? = nil) {
        let bytes = HandshakeCodec.encodePairingResponse(status: status, token: token, macName: pairingMacName)
        channel.send(bytes) { _ in
            // Pairing connections never stream: close after the reply either
            // way. On success the client reconnects with the issued token.
            channel.cancel()
        }
    }

    private func sendAuthResponse(_ channel: NWConnectionChannel, status: HandshakeStatus, thenClose: Bool) {
        let bytes = HandshakeCodec.encodeResponse(status: status)
        channel.send(bytes) { _ in
            if thenClose {
                debugLog("Auth rejected (\(status)), closing connection")
                channel.cancel()
            }
        }
    }
}
