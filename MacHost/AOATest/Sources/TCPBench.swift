import Foundation
import Network

/// Baseline: the exact same block protocol over the current transport
/// (adb reverse TCP). Run `adb reverse tcp:54399 tcp:54399`, start this,
/// then tap "TCP baseline" in the aoabench app.
enum TCPBenchRunner {
    static func run(config: BenchConfig, port: UInt16) throws {
        let session = BenchSession(config: config)
        let queue = DispatchQueue(label: "tcpbench.io")
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        var connection: NWConnection?
        var running = true
        let connected = DispatchSemaphore(value: 0)

        listener.newConnectionHandler = { conn in
            guard connection == nil else {
                conn.cancel()
                return
            }
            connection = conn
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    print("Client connected: \(conn.endpoint)")
                    connected.signal()
                }
                if case .failed = state { running = false }
                if case .cancelled = state { running = false }
            }
            conn.start(queue: queue)
        }
        listener.start(queue: queue)
        print("Listening on port \(port). Run `adb reverse tcp:\(port) tcp:\(port)`, then start TCP baseline in aoabench.")
        connected.wait()
        guard let conn = connection else { return }

        // Receive loop for ACK/PONG.
        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data = data, !data.isEmpty {
                    session.consumeUplink(data)
                }
                if error == nil && !done && running {
                    receiveLoop()
                } else {
                    running = false
                }
            }
        }
        receiveLoop()

        // Send loop: keep `inflight` blocks in the Network.framework pipeline.
        guard let block = NSMutableData(length: session.blockSize) else { fatalError("alloc") }
        func sendNext() {
            guard running else { return }
            _ = session.fillNextBlock(block)
            let data = Data(bytes: block.bytes, count: block.length)
            conn.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    session.recordError()
                    running = false
                    return
                }
                session.recordCompletion(bytes: data.count)
                session.maybeReport()
                sendNext()
            })
        }
        for _ in 0..<config.inflight {
            queue.async { sendNext() }
        }

        Thread.sleep(forTimeInterval: TimeInterval(config.seconds))
        running = false
        conn.cancel()
        listener.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        session.printSummary()
    }
}
