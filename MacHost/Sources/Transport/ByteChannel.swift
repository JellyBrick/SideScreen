import Foundation
import Network

/// How much the transport itself vouches for the peer.
/// - physicallySecured: the bytes ride a physical link the user plugged in
///   (USB via adb reverse loopback today, AOA bulk later) — no token needed.
/// - networkAuthenticated: reached over the LAN and passed the SSWA token
///   handshake.
enum ChannelTrust {
    case physicallySecured
    case networkAuthenticated
}

enum ChannelKind {
    case tcpLoopback
    case tcpLan
    case aoa
}

/// A reliable, ordered, bidirectional byte stream that has already cleared
/// transport-level authentication. The streaming protocol layer talks only to
/// this — NWConnection (TCP) and the AOA bulk pipe both implement it.
///
/// The receive contract mirrors NWConnection.receive: the completion gets
/// (data, isComplete, error) and delivers between `minimum` and `maximum`
/// bytes unless the stream ends first.
protocol ByteChannel: AnyObject {
    var kind: ChannelKind { get }
    var trust: ChannelTrust { get }
    func send(_ data: Data, completion: ((Error?) -> Void)?)
    func receive(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void)
    func cancel()
}

/// Produces established channels. Implementations own listener/attach
/// mechanics AND transport-specific authentication: a channel handed to
/// `onChannelEstablished` is ready for the streaming protocol.
protocol ChannelSource: AnyObject {
    /// A raw peer showed up and is about to be vetted. The server uses this
    /// to preempt the active session (single-client policy) exactly like the
    /// pre-refactor accept path did.
    var onIncomingConnection: ((ByteChannel) -> Void)? { get set }
    /// The peer cleared transport-level auth (or was loopback/physical) and
    /// may start the streaming protocol.
    var onChannelEstablished: ((ByteChannel) -> Void)? { get set }
    /// The channel ended (error, cancel, or peer close).
    var onChannelClosed: ((ByteChannel) -> Void)? { get set }
    func start()
    func stop()
}

final class NWConnectionChannel: ByteChannel {
    let connection: NWConnection
    let kind: ChannelKind

    var trust: ChannelTrust {
        kind == .tcpLoopback ? .physicallySecured : .networkAuthenticated
    }

    init(connection: NWConnection, kind: ChannelKind) {
        self.connection = connection
        self.kind = kind
    }

    func send(_ data: Data, completion: ((Error?) -> Void)?) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    func receive(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func cancel() {
        connection.cancel()
    }
}
