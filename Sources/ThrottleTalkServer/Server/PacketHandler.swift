import Foundation
import NIOCore
import Logging

/// NIO inbound handler that decodes TTLK packets and routes them through the
/// `ChannelManager`.
///
/// This sits in the UDP `DatagramBootstrap` pipeline. Every incoming datagram
/// is decoded and dispatched based on packet type:
/// - **Audio**: forwarded to all other participants in the channel (SFU relay).
/// - **Heartbeat**: keeps the participant session alive; also acts as an
///   implicit join if the participant is not yet registered.
/// - **Control**: logged for future expansion (Phase 2).
public final class PacketHandler: ChannelInboundHandler {

    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let channelManager: ChannelManager
    private let logger: Logger

    /// Total packets received (for periodic logging).
    private var totalPacketsReceived: Int = 0
    /// Total packets that failed to decode.
    private var totalMalformed: Int = 0
    /// Total packets forwarded.
    private var totalForwarded: Int = 0

    public init(channelManager: ChannelManager, logger: Logger) {
        self.channelManager = channelManager
        self.logger = logger
    }

    // MARK: - ChannelInboundHandler

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let senderAddress = envelope.remoteAddress

        totalPacketsReceived += 1

        // Log first packet and every 100th to confirm packets are arriving.
        if totalPacketsReceived == 1 {
            logger.info("First UDP packet received from \(senderAddress) (\(buffer.readableBytes) bytes)")
        } else if totalPacketsReceived % 100 == 0 {
            logger.info("Packets: \(totalPacketsReceived) received, \(totalMalformed) malformed, \(totalForwarded) forwarded")
        }

        guard let packet = PacketCodec.decode(buffer: &buffer) else {
            totalMalformed += 1
            // Log at warning level so we can always see decode failures.
            logger.warning("Dropped malformed packet from \(senderAddress) (\(envelope.data.readableBytes) bytes, malformed #\(totalMalformed))")
            return
        }

        switch packet.type {
        case .audio:
            handleAudio(packet: packet, senderAddress: senderAddress, context: context)

        case .heartbeat:
            handleHeartbeat(packet: packet, senderAddress: senderAddress, context: context)

        case .control:
            handleControl(packet: packet, senderAddress: senderAddress, context: context)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("PacketHandler error: \(error)")
    }

    // MARK: - Packet Dispatch

    /// Forward audio to all other participants if VOX is active.
    private func handleAudio(packet: Packet, senderAddress: SocketAddress, context: ChannelHandlerContext) {
        // Only forward when the sender's VOX flag is set.
        guard packet.flags.contains(.voxActive) else {
            return
        }

        // Ensure the participant is known (update address in case of NAT rebind).
        channelManager.handleJoin(
            channelID: packet.channelID,
            participantID: packet.participantID,
            address: senderAddress
        )

        // Rate limit: drop packets from participants sending too fast.
        if let channel = channelManager.channel(for: packet.channelID) {
            guard channel.checkRateLimit(for: packet.participantID) else {
                logger.debug("Rate limited audio from \(packet.participantID)")
                return
            }
        }

        channelManager.forward(packet: packet, from: packet.participantID, context: context)
    }

    /// Update the participant's heartbeat and broadcast to other participants
    /// so they learn display names and presence.
    private func handleHeartbeat(packet: Packet, senderAddress: SocketAddress, context: ChannelHandlerContext) {
        channelManager.handleJoin(
            channelID: packet.channelID,
            participantID: packet.participantID,
            address: senderAddress
        )

        if let channel = channelManager.channel(for: packet.channelID) {
            channel.updateParticipant(id: packet.participantID, address: senderAddress, flags: packet.flags)
        }

        // Broadcast heartbeat to all other participants so they can display
        // rider names and admin status.
        channelManager.forward(packet: packet, from: packet.participantID, context: context)

        logger.trace("Heartbeat from \(packet.participantID) on channel \(packet.channelID)")
    }

    /// Handle control packets — admin commands like mute/kick, and leave notifications.
    private func handleControl(packet: Packet, senderAddress: SocketAddress, context: ChannelHandlerContext) {
        guard packet.payload.count >= 1 else {
            logger.debug("Control packet payload too small (\(packet.payload.count) bytes)")
            return
        }

        let commandByte = packet.payload[0]

        // Leave command (0x30) doesn't require admin privileges.
        if commandByte == 0x30 {
            channelManager.handleLeave(channelID: packet.channelID, participantID: packet.participantID)
            logger.info("Participant \(packet.participantID) sent leave on channel \(packet.channelID)")
            return
        }

        // All other commands require verified admin privileges.
        // Check the channel's admin registry (populated from heartbeats) — not just
        // the packet flag, which could be spoofed by a malicious client.
        let isVerifiedAdmin: Bool
        if let channel = channelManager.channel(for: packet.channelID) {
            isVerifiedAdmin = channel.isAdmin(packet.participantID)
        } else {
            isVerifiedAdmin = false
        }

        guard isVerifiedAdmin else {
            logger.warning("Control packet from non-admin \(packet.participantID) — ignoring (flag: \(packet.flags.contains(.admin)))")
            return
        }

        guard packet.payload.count >= 17 else {
            logger.debug("Control packet payload too small for admin command (\(packet.payload.count) bytes)")
            return
        }
        let targetIDData = packet.payload.subdata(in: 1..<17)
        let targetID = targetIDData.withUnsafeBytes { ptr -> UUID in
            let raw = ptr.bindMemory(to: uuid_t.self)
            return UUID(uuid: raw[0])
        }

        logger.info("Control command 0x\(String(commandByte, radix: 16)) from \(packet.participantID) targeting \(targetID)")

        switch commandByte {
        case 0x01: // muteParticipant
            sendControlToTarget(
                responseByte: 0x10, // youWereMuted
                targetID: targetID,
                channelID: packet.channelID,
                senderID: packet.participantID,
                context: context
            )

        case 0x02: // unmuteParticipant
            sendControlToTarget(
                responseByte: 0x11, // youWereUnmuted
                targetID: targetID,
                channelID: packet.channelID,
                senderID: packet.participantID,
                context: context
            )

        case 0x03: // kickParticipant
            sendControlToTarget(
                responseByte: 0x12, // youWereKicked
                targetID: targetID,
                channelID: packet.channelID,
                senderID: packet.participantID,
                context: context
            )
            // Also broadcast that the participant left.
            channelManager.handleLeave(channelID: packet.channelID, participantID: targetID)

        default:
            logger.debug("Unknown control command 0x\(String(commandByte, radix: 16))")
        }
    }

    /// Send a control response packet to a specific target participant.
    private func sendControlToTarget(
        responseByte: UInt8,
        targetID: UUID,
        channelID: UUID,
        senderID: UUID,
        context: ChannelHandlerContext
    ) {
        guard let channel = channelManager.channel(for: channelID),
              let target = channel.participant(for: targetID) else {
            return
        }

        // Build response payload: [command byte] + [target UUID]
        var payload = Data([responseByte])
        let u = targetID.uuid
        payload.append(contentsOf: [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                                    u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])

        let responsePacket = Packet(
            type: .control,
            sequenceNumber: 0,
            timestamp: 0,
            channelID: channelID,
            participantID: senderID,
            flags: [.admin],
            payload: payload
        )

        var outBuffer = context.channel.allocator.buffer(capacity: kPacketHeaderSize + payload.count + kPacketCRCSize)
        PacketCodec.encode(packet: responsePacket, buffer: &outBuffer)

        let envelope = AddressedEnvelope(remoteAddress: target.remoteAddress, data: outBuffer)
        context.writeAndFlush(NIOAny(envelope), promise: nil)
    }
}
