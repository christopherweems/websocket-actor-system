/*
 See LICENSE folder for this sample’s licensing information.

 Abstract:
 WebSocket based client/server style actor system implementation.
 */

import Distributed
import Foundation
import Logging
import NIO
import NIOWebSocket

#if canImport(Network)
    import NIOTransportServices
#else
    import NIOPosix
#endif

typealias CallID = UUID

enum WebSocketWireEnvelope: Sendable, Codable {
    case call(RemoteWebSocketCallEnvelope)
    case reply(WebSocketReplyEnvelope)
    case connectionClose
}

struct WebSocketReplyEnvelope: Sendable, Codable {
    let callID: CallID
    let sender: WebSocketActorSystem.ActorID?
    let value: Data
}

struct RemoteWebSocketCallEnvelope: Sendable, Codable {
    let callID: CallID
    let recipient: ActorIdentity
    let invocationTarget: String
    let genericSubs: [String]
    let args: [Data]
}

typealias WebSocketAgentChannel = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
typealias WebSocketOutbound = NIOAsyncChannelOutboundWriter<WebSocketFrame>

public enum WebSocketActorSystemMode {
    case client(of: ServerAddress)
    case server(at: ServerAddress)
    case localOnly
}

/// A distributed actor system that uses WebSockets to allow multiple clients
/// to communicate with a single server.
///
/// ## Logging
///
/// The `WebSocketActorSystem` uses [swift-log](https://github.com/apple/swift-log)
/// to output debugging information. You can control the level of detail and destination of this logging
/// by customizing the `logger` parameter to the ``init(id:logger:)`` function, or by
/// modifying the ``defaultLogger`` static property before you create your ``WebSocketActorSystem``.
///
/// This library outputs at these log levels. Later levels include earlier levels.
///
/// - term `.critical`: Errors encountered inside the actor system that may not
///   be recoverable.
/// - term `.error`: Incorrect use of the distributed actor system by the application,
///   such as using the same id for multiple objects.
/// - term `.warning`: Recoverable errors encountered inside the actor system, such as network errors.
/// - term `.notice`: Information about client connections and disconnections.
/// - term `.info`: Information about distributed function calls. Note that this level does not
///   include function arguments or return values.
/// - term `.debug`: Additional information about function call arguments,
///   return values, and thrown exceptions. Note that this may include private data,
///   so you should not enable this level of logging unless you are troubleshooting a problem.
/// - term `.trace`: Detailed information about the internals of the ``WebSocketActors``
///   implementation.

public final class WebSocketActorSystem: DistributedActorSystem,
    @unchecked /* state protected with locks */ Sendable
{
    public typealias ActorID = ActorIdentity
    public typealias ResultHandler = WebSocketActorSystemResultHandler
    public typealias InvocationEncoder = NIOInvocationEncoder
    public typealias InvocationDecoder = NIOInvocationDecoder
    public typealias SerializationRequirement = any Codable

    typealias OnDemandResolveHandler = (ActorID) -> (any DistributedActor)?

    public static let defaultLogger = Logger(label: "WebSocketActors")

    public let nodeID: NodeIdentity
    public let logger: Logger
    private let pendingReplies = PendingReplies()

    /// The ``manager`` encapsulates the differences between the client and the server.
    /// It opens communications with other nodes and maps NodeIDs to RemoteNodes.
    ///
    /// Although this is a `var`, it is set during initialization and never changed.
    /// It is only a var to solve initialization problems.
    private var managers: [Manager] = []
    private var remoteNodes: RemoteNodeDirectory

    /// The ``lock`` limits access to `managedActors` and `resolveOnDemandHandler`.
    /// These properties are used in synchronous code, and the lock makes them thread-safe.
    private let lock = NSLock()
    private var managedActors: [ActorID: any DistributedActor] = [:]
    private var resolveOnDemandHandler: OnDemandResolveHandler?

    public var monitor: ResilientTask.MonitorFunction?

    /// Create a new ``WebSocketActorSystem``.
    ///
    /// - Parameter id: The ``NodeIdentity`` of this node. Defaults to a random value.
    /// - Parameter logger: The ``Logger`` to use for logging. Defaults to ``defaultLogger``.
    /// - Parameter connectionTimeout: The maximum time to wait for connections to be established.
    ///   This controls now long to wait for a node to connect with a needed ``NodeIdentity``.
    ///   Defaults to 5 seconds.
    ///
    /// Whenever a connection is made between a client and a server, they exchange node IDs to
    /// identify themselves. If a client tries to call a remote actor, but the node ID of the remote actor
    /// doesn't match an existing connection, the `connectionTimeout` controls how long the
    /// actor system will wait for a connection to be established. If the timeout expires, the call will
    /// throw a ``WebSocketActorSystemError/timeoutWaitingForNodeID(id:timeout:)`` error.
    public init(id: NodeIdentity = .random(),
                logger: Logger = defaultLogger,
                connectionTimeout: Duration = .seconds(5))
    {
        nodeID = id
        self.logger = logger
        remoteNodes = RemoteNodeDirectory(timeout: connectionTimeout)
    }

    @discardableResult
    public func runServer(at address: ServerAddress) async throws -> ServerManager {
        guard address.scheme == .insecure else {
            logger.error("""
            The WebSocketActorSystem only supports insecure server mode. \
            Use a proxy server to provide secure connections.
            """)
            throw WebSocketActorSystemError.secureServerNotSupported
        }
        let server = await createServerManager(at: address)
        managers.append(server)
        return server
    }

    @discardableResult
    public func connectClient(to address: ServerAddress) async throws -> ClientManager {
        let client = await createClientManager(to: address)
        logger.info("client connected to \(address)")
        return client
    }

    func dispatchIncomingFrames(channel: WebSocketAgentChannel, remoteNodeID: NodeIdentity) async throws {
        try await RemoteNode.withRemoteNode(nodeID: remoteNodeID, channel: channel) { remoteNode in
            logger.trace("opened remoteNode for \(remoteNodeID) on \(TaskPath.current)")
            await remoteNodes.opened(remote: remoteNode)

            try await TaskPath.with(name: "remoteNode") {
                for try await frame in remoteNode.inbound {
                    switch frame.opcode {
                    case .connectionClose:
                        // Close the connection.
                        //
                        // We might also want to inform the actor system that this connection
                        // went away, so it can terminate any tasks or actors working to
                        // inform the remote receptionist on the now-gone system about our
                        // actors.

                        // This is an unsolicited close. We're going to send a response frame and
                        // then, when we've sent it, close up shop. We should send back the close code the remote
                        // peer sent us, unless they didn't send one at all.
                        logger.trace("Received close")
                        var data = frame.unmaskedData
                        let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
                        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
                        try await remoteNode.outbound.write(closeFrame)

                    case .text:
                        var data = frame.unmaskedData
                        let text = data.getString(at: 0, length: data.readableBytes) ?? ""
                        self.logger.withOp()
                            .trace("Received: \(text), from: \(String(describing: channel.channel.remoteAddress))")

                        await self.decodeAndDeliver(data: &data, from: remoteNode)

                    case .ping:
                        logger.trace("Received ping")
                        var frameData = frame.data
                        let maskingKey = frame.maskKey

                        if let maskingKey {
                            frameData.webSocketUnmask(maskingKey)
                        }

                        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
                        try await remoteNode.outbound.write(responseFrame)

                    case .pong:
                        logger.trace("Received pong")

                    case .binary, .continuation:
                        // We ignore these frames.
                        break
                    default:
                        // Unknown frames are errors.
                        await self.closeOnError(channel: channel)
                    }
                }
            }
            logger.trace("closing remoteNode for \(remoteNodeID) on \(TaskPath.current)")
            await remoteNodes.closing(remote: remoteNode)
        }
    }

    public func shutdownGracefully() async {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            await withDiscardingTaskGroup { group in
                for manager in managers {
                    group.addTask {
                        await manager.cancel()
                    }
                }
            }
        }
        else {
            // Fallback on earlier versions
            await withTaskGroup(of: Void.self) { group in
                for manager in managers {
                    group.addTask {
                        await manager.cancel()
                    }
                }
            }
        }
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act: DistributedActor, Act.ID == ActorID {
        // Implements `id` hinting via a task-local.
        // IDs must never be reused, so if this were to happen this causes a crash here.
        if let hintedID = Self.actorIDHint {
            if !Self.alreadyLocked {
                lock.lock()
            }
            defer {
                if !Self.alreadyLocked {
                    lock.unlock()
                }
            }

            if let existingActor = managedActors[hintedID] {
                preconditionFailure("""
                Illegal re-use of ActorID (\(hintedID))!
                Already used by: \(existingActor), yet attempted to assign to \(actorType)!
                """)
            }

            return hintedID
        }

        let uuid = UUID().uuidString
        let typeFullName = "\(Act.self)"
        guard typeFullName.split(separator: ".").last != nil else {
            return .init(id: uuid)
        }

        return .init(id: "\(uuid)")
    }

    /// Register the actor as a local actor.
    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        logger.with(actor.id).trace("actorReady")

        if !Self.alreadyLocked {
            lock.lock()
        }
        defer {
            if !Self.alreadyLocked {
                self.lock.unlock()
            }
        }

        managedActors[actor.id] = actor
    }

    /// Unregister the actors as a local actor.
    public func resignID(_ id: ActorID) {
        logger.with(id).trace("resignID")
        lock.lock()
        defer {
            lock.unlock()
        }

        managedActors.removeValue(forKey: id)
    }

    // Trick to allow resolve() re-entrancy while still holding the `lock`
    @TaskLocal private static var alreadyLocked: Bool = false

    /// Attempt to resolve the `id` to a local actor.
    /// Returns `nil` if the id cannot be resolved locally, which implies the id
    /// represents a remote actor.
    public func resolve<Act>(id: ActorID, as _: Act.Type) throws -> Act?
        where Act: DistributedActor, Act.ID == ActorID
    {
        if !Self.alreadyLocked {
            lock.lock()
        }
        defer {
            if !Self.alreadyLocked {
                lock.unlock()
            }
        }

        let taggedLogger = logger.with(id).withOp()

        guard let found = managedActors[id] else {
            taggedLogger.trace("not found locally")
            if let resolveOnDemand = resolveOnDemandHandler {
                taggedLogger.trace("resolve on demand")

                let resolvedOnDemandActor = Self.$alreadyLocked.withValue(true) {
                    resolveOnDemand(id)
                }
                if let resolvedOnDemandActor {
                    taggedLogger.trace("attempt to resolve on-demand as \(resolvedOnDemandActor)")
                    if let wellTyped = resolvedOnDemandActor as? Act {
                        taggedLogger.trace("resolved on-demand as \(Act.self)")
                        return wellTyped
                    }
                    else {
                        taggedLogger.error("resolved on demand, but wrong type: \(type(of: resolvedOnDemandActor))")
                        throw WebSocketActorSystemError.resolveFailed(id: id)
                    }
                }
                else {
                    taggedLogger.trace("resolve on demand")
                }
            }

            taggedLogger.trace("resolved as remote")
            return nil // definitely remote, we don't know about this ActorID
        }

        guard let wellTyped = found as? Act else {
            throw WebSocketActorSystemError.resolveFailedToMatchActorType(found: type(of: found), expected: Act.self)
        }

        logger.trace("RESOLVED LOCAL: \(wellTyped)")
        return wellTyped
    }

    func resolveAny(id: ActorID) -> (any DistributedActor)? {
        lock.lock()
        defer { lock.unlock() }

        let taggedLogger = logger.with(id).withOp()

        guard let resolved = managedActors[id] else {
            taggedLogger.trace("here")
            if let resolveOnDemand = resolveOnDemandHandler {
                taggedLogger.trace("got handler")
                return Self.$alreadyLocked.withValue(true) {
                    if let resolvedOnDemandActor = resolveOnDemand(id) {
                        taggedLogger.trace("Resolved ON DEMAND as \(resolvedOnDemandActor)")
                        return resolvedOnDemandActor
                    }
                    else {
                        taggedLogger.trace("not resolved")
                        return nil
                    }
                }
            }
            else {
                taggedLogger.trace("no resolveOnDemandHandler")
            }

            taggedLogger.trace("definitely remote")
            return nil // definitely remote, we don't know about this ActorID
        }

        taggedLogger.trace("resolved as \(resolved)")
        return resolved
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        .init()
    }

    /// Retrieve custom information about the remote node the actor is running on.
    /// You can use this to store context such as user login information.
    /// This function always returns nil when called outside of a distributed actor.
    public func getNodeInfo(key: ActorSystemUserInfoKey) async throws -> (any Sendable)? {
        guard let remoteNode = RemoteNode.current else {
            throw WebSocketActorSystemError.notInDistributedActor
        }
        return await remoteNode.getUserInfo(key: key)
    }

    /// Set custom information about the remote node the actor is running on.
    public func setNodeInfo(key: ActorSystemUserInfoKey, value: any Sendable) async throws {
        guard let remoteNode = RemoteNode.current else {
            throw WebSocketActorSystemError.notInDistributedActor
        }
        await remoteNode.setUserInfo(key: key, value: value)
    }
}

public extension WebSocketActorSystem {
    func registerOnDemandResolveHandler(resolveOnDemand: @escaping (ActorID) -> (any DistributedActor)?) {
        lock.lock()
        defer {
            self.lock.unlock()
        }

        resolveOnDemandHandler = resolveOnDemand
    }

    @TaskLocal internal static var actorIDHint: ActorID?

    /// Create a local actor with the specified id.
    func makeLocalActor<Act>(id: ActorID, _ factory: () -> Act) -> Act
        where Act: DistributedActor, Act.ActorSystem == WebSocketActorSystem
    {
        Self.$actorIDHint.withValue(id.with(nodeID)) {
            factory()
        }
    }

    /// Create a local actor with a random id prefixed with the actor's type.
    func makeLocalActor<Act>(_ factory: () -> Act) -> Act
        where Act: DistributedActor, Act.ActorSystem == WebSocketActorSystem
    {
        Self.$actorIDHint.withValue(.random(for: Act.self, node: nodeID)) {
            factory()
        }
    }
}

extension WebSocketActorSystem {
    func decodeAndDeliver(data: inout ByteBuffer, from remote: RemoteNode) async {
        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self

        let taggedLogger = logger.withOp()

        do {
            let wireEnvelope = try data.readJSONDecodable(WebSocketWireEnvelope.self, length: data.readableBytes)

            switch wireEnvelope {
            case .call(let remoteCallEnvelope):
                // log("receive-decode-deliver", "Decode remoteCall...")
                receiveInboundCall(envelope: remoteCallEnvelope, on: remote)
            case .reply(let replyEnvelope):
                try await receiveInboundReply(envelope: replyEnvelope)
            case .none, .connectionClose:
                taggedLogger.error("Failed decoding: \(data); decoded empty")
            }
        }
        catch {
            taggedLogger.error("Failed decoding: \(data), error: \(error)")
        }
        taggedLogger.trace("done")
    }

    func receiveInboundCall(envelope: RemoteWebSocketCallEnvelope, on remote: RemoteNode) {
        let taggedLogger = logger.withOp().with(envelope)
        taggedLogger.info("receiveInboundCall")
        taggedLogger.with(envelope.args).debug("args")
        Task {
            taggedLogger.trace("Calling resolveAny(id: \(envelope.recipient))")
            guard let anyRecipient = resolveAny(id: envelope.recipient) else {
                taggedLogger.warning("failed to resolve \(envelope.recipient)")
                return
            }
            taggedLogger.trace("Recipient: \(anyRecipient)")
            let target = RemoteCallTarget(envelope.invocationTarget)
            taggedLogger.trace("Target: \(target)")
            taggedLogger.trace("Target.identifier: \(target.identifier)")
            let handler = ResultHandler(actorSystem: self, callID: envelope.callID, system: self, remote: remote)
            taggedLogger.trace("Handler: \(anyRecipient)")

            do {
                var decoder = NIOInvocationDecoder(system: self, envelope: envelope)
                func doExecuteDistributedTarget<Act: DistributedActor>(recipient: Act) async throws {
                    taggedLogger.trace("executeDistributedTarget")
                    try await executeDistributedTarget(on: recipient,
                                                       target: target,
                                                       invocationDecoder: &decoder,
                                                       handler: handler)
                }

                // As implicit opening of existential becomes part of the language,
                // this underscored feature is no longer necessary. Please refer to
                // SE-352 Implicitly Opened Existentials:
                // https://github.com/apple/swift-evolution/blob/main/proposals/0352-implicit-open-existentials.md
                try await _openExistential(anyRecipient, do: doExecuteDistributedTarget)
            }
            catch {
                taggedLogger
                    .error("failed to executeDistributedTarget [\(target)] on [\(anyRecipient)], error: \(error)")
                try? await handler.onThrow(error: error)
            }
        }
    }

    func receiveInboundReply(envelope: WebSocketReplyEnvelope) async throws {
        let taggedLogger = logger.withOp().with(envelope.callID).with(sender: envelope.sender)
        taggedLogger.info("receiveInboundReply")
        try await pendingReplies.receivedReply(callID: envelope.callID, data: envelope.value)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: RemoteCall implementations

public extension WebSocketActorSystem {
    func remoteCall<Act, Err, Res>(on actor: Act,
                                   target: RemoteCallTarget,
                                   invocation: inout InvocationEncoder,
                                   throwing _: Err.Type,
                                   returning _: Res.Type) async throws -> Res where Act: DistributedActor,
        Act.ID == ActorID, Err: Error, Res: Codable
    {
        let taggedLogger = logger.withOp().with(actor.id).with(target)
        taggedLogger.info("remoteCall")
        taggedLogger.trace("Call to: \(actor.id), target: \(target), target.identifier: \(target.identifier)")

        let remoteNode = try await remoteNodes.remoteNode(for: actor.id)

        taggedLogger.trace("Prepare [\(target)] call...")

        let localInvocation = invocation
        let targetIdentifier = target.identifier
        let genericSubs = localInvocation.genericSubs
        let argumentData = localInvocation.argumentData
        let replyData = try await pendingReplies.sendMessage { callID in
            let callEnvelope = RemoteWebSocketCallEnvelope(callID: callID,
                                                           recipient: actor.id,
                                                           invocationTarget: targetIdentifier,
                                                           genericSubs: genericSubs,
                                                           args: argumentData)
            let wireEnvelope = WebSocketWireEnvelope.call(callEnvelope)

            taggedLogger.trace("Write envelope: \(wireEnvelope)")

//            let frame = WebSocketFrame(opcode: .text, data: try JSONEncoder().encode(wireEnvelope))

            try await remoteNode.write(actorSystem: self, envelope: wireEnvelope)
        }

        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.actorSystemKey] = self

            return try decoder.decode(Res.self, from: replyData)
        }
        catch {
            throw WebSocketActorSystemError.decodingError(error: error)
        }
    }

    func remoteCallVoid<Act, Err>(on actor: Act,
                                  target: RemoteCallTarget,
                                  invocation: inout InvocationEncoder,
                                  throwing _: Err.Type) async throws where Act: DistributedActor, Act.ID == ActorID,
        Err: Error
    {
        let taggedLogger = logger.withOp().with(actor.id)
        taggedLogger.trace("Call to: \(actor.id), target: \(target), target.identifier: \(target.identifier)")

        let remoteNode = try await remoteNodes.remoteNode(for: actor.id)
        let localInvocation = invocation
        let targetIdentifier = target.identifier
        let genericSubs = localInvocation.genericSubs
        let argumentData = localInvocation.argumentData

        taggedLogger.trace("Prepare [\(target)] call...")
        _ = try await pendingReplies.sendMessage { callID in
            let callEnvelope = RemoteWebSocketCallEnvelope(callID: callID,
                                                           recipient: actor.id,
                                                           invocationTarget: targetIdentifier,
                                                           genericSubs: genericSubs,
                                                           args: argumentData)
            let wireEnvelope = WebSocketWireEnvelope.call(callEnvelope)

            taggedLogger.trace("Write envelope: \(wireEnvelope)")

            try await remoteNode.write(actorSystem: self, envelope: wireEnvelope)
        }

        taggedLogger.trace("COMPLETED CALL: \(target)")
    }

    internal func write(remote: RemoteNode,
                        envelope: WebSocketWireEnvelope) async throws
    {
        let taggedLogger = logger.withOp()
        taggedLogger.trace("unwrap WebSocketWireEnvelope")

        switch envelope {
        case .connectionClose:
            var data = remote.channel.channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: .protocolError)
            let frame = WebSocketFrame(fin: true,
                                       opcode: .connectionClose,
                                       data: data)
            try await remote.outbound.write(frame)
//            try await remote.channel.channel.close()
        case .reply, .call:
            let encoder = JSONEncoder()
            encoder.userInfo[.actorSystemKey] = self

            do {
                var data = ByteBuffer()
                try data.writeJSONEncodable(envelope, encoder: encoder)
                taggedLogger.trace("Write: \(envelope)")

                let frame = WebSocketFrame(fin: true, opcode: .text, data: data)
                try await remote.outbound.write(frame)
            }
            catch {
                taggedLogger.error("Failed to serialize call [\(envelope)], error: \(error)")
            }
        }
    }
}

public struct WebSocketActorSystemResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = any Codable

    let actorSystem: WebSocketActorSystem
    let callID: CallID
    let system: WebSocketActorSystem
    let remote: RemoteNode

    public func onReturn<Success: Codable>(value: Success) async throws {
        system.logger.withOp().with(callID).trace("returning \(value)")
        let encoder = JSONEncoder()
        encoder.userInfo[.actorSystemKey] = actorSystem
        let returnValue = try encoder.encode(value)
        let envelope = WebSocketReplyEnvelope(callID: callID, sender: nil, value: returnValue)
        try await actorSystem.write(remote: remote, envelope: WebSocketWireEnvelope.reply(envelope))
    }

    public func onReturnVoid() async throws {
        system.logger.withOp().with(callID).trace("returning Void")
        let envelope = WebSocketReplyEnvelope(callID: callID, sender: nil, value: "".data(using: .utf8)!)
        try await actorSystem.write(remote: remote, envelope: WebSocketWireEnvelope.reply(envelope))
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        system.logger.withOp().with(callID).trace("throwing \(error)")
        // Naive best-effort carrying the error name back to the caller;
        // Always be careful when exposing error information -- especially do not ship back the entire description
        // or error of a thrown value as it may contain information which should never leave the node.
        let envelope = WebSocketReplyEnvelope(callID: callID, sender: nil, value: "".data(using: .utf8)!)
        try await actorSystem.write(remote: remote, envelope: WebSocketWireEnvelope.reply(envelope))
    }
}

public enum WebSocketActorSystemError: Error, DistributedActorSystemError {
    case resolveFailedToMatchActorType(found: Any.Type, expected: Any.Type)
    case noPeers
    case notEnoughArgumentsInEnvelope(expected: Any.Type)
    case failedDecodingResponse(data: Data, error: Error)
    case decodingError(error: Error)
    case resolveFailed(id: WebSocketActorSystem.ActorID)

    /// We are trying to send a message to a remote actor, but that actor does not
    /// have a NodeIdentity. This probably means that the remote node passed us an actor
    /// that was not constructed using the `WebSocketActorSystem.makeActor(id:_:)`,
    /// as it should have been.
    case missingNodeID(id: WebSocketActorSystem.ActorID)

    /// We are trying to send a message to a remote actor, but we do not currently
    /// have an open `Channel` to the remote node. This is currently an error.
    /// Future versions of this library may attempt to reconnect to the remote node
    /// instead of throwing this error.
    case noRemoteNode

    case failedToUpgrade

    case missingReplyContinuation(callID: UUID)

    case secureServerNotSupported

    /// Attempt to get or set node info outside of a distributed actor.
    case notInDistributedActor

    case timeoutWaitingForNodeID(id: NodeIdentity?, timeout: Duration)
}
