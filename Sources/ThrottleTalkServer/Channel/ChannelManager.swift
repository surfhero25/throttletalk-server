import Foundation
import NIOCore
import Logging

/// Central registry of voice channels and the forwarding engine for the SFU.
///
/// All public methods are called from the NIO event loop, so no locking is
/// required. The manager owns channel lifecycle: creation, participant routing,
/// and cleanup of stale sessions.
public final class ChannelManager {

    /// Active voice channels keyed by channel UUID.
    private var channels: [UUID: VoiceChannel] = [:]

    /// Server-wide configuration (limits, timeouts).
    private let config: ServerConfig

    /// Logger instance scoped to the channel manager.
    private let logger: Logger

    public init(config: ServerConfig, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    // MARK: - Channel Lifecycle

    /// Return an existing channel or create a new one if the limit allows.
    ///
    /// If the maximum channel count has been reached and no channel exists for
    /// the given ID, this still returns the channel (creating it) to avoid
    /// silently dropping participants. Logging warns when the soft cap is hit.
    public func getOrCreateChannel(id: UUID) -> VoiceChannel {
        if let existing = channels[id] {
            return existing
        }
        if channels.count >= config.maxChannels {
            logger.warning("Channel limit reached (\(config.maxChannels)). Creating channel \(id) anyway.")
        }
        let channel = VoiceChannel(id: id)
        channels[id] = channel
        logger.info("Channel created: \(id)")
        return channel
    }

    /// Remove a channel entirely.
    public func removeChannel(id: UUID) {
        channels.removeValue(forKey: id)
        logger.info("Channel removed: \(id)")
    }

    /// Look up a channel by ID.
    public func channel(for id: UUID) -> VoiceChannel? {
        channels[id]
    }

    // MARK: - Participant Management

    /// Handle a participant joining (or re-joining) a channel.
    public func handleJoin(channelID: UUID, participantID: UUID, address: SocketAddress) {
        let channel = getOrCreateChannel(id: channelID)

        if channel.participant(for: participantID) != nil {
            // Participant already known -- update address (NAT rebinding).
            channel.updateParticipant(id: participantID, address: address)
            logger.debug("Participant \(participantID) re-joined channel \(channelID)")
        } else {
            if channel.participantCount >= config.maxParticipantsPerChannel {
                logger.warning("Channel \(channelID) participant limit reached (\(config.maxParticipantsPerChannel)). Ignoring join for \(participantID).")
                return
            }
            let participant = Participant(id: participantID, remoteAddress: address)
            channel.addParticipant(participant)
            logger.info("Participant \(participantID) joined channel \(channelID) (\(channel.participantCount) total)")
        }
    }

    /// Handle an explicit leave request from a participant.
    public func handleLeave(channelID: UUID, participantID: UUID) {
        guard let channel = channels[channelID] else { return }
        channel.removeParticipant(id: participantID)
        logger.info("Participant \(participantID) left channel \(channelID) (\(channel.participantCount) remaining)")
        if channel.participantCount == 0 {
            removeChannel(id: channelID)
        }
    }

    // MARK: - Forwarding (SFU Core)

    /// Forward a packet to every other participant in the same channel.
    ///
    /// This is the hot path of the SFU. The packet is re-encoded once and then
    /// written to each recipient's address via the NIO channel context.
    /// Total packets forwarded (for diagnostics).
    private var totalForwarded: Int = 0

    public func forward(packet: Packet, from senderID: UUID, context: ChannelHandlerContext) {
        guard let channel = channels[packet.channelID] else {
            logger.warning("Forward: no channel \(packet.channelID) for sender \(senderID)")
            return
        }

        let recipients = channel.allParticipants(except: senderID)
        guard !recipients.isEmpty else {
            // Log occasionally when there are no recipients — helps diagnose single-participant issues.
            if packet.type == .heartbeat {
                logger.info("Forward: no other participants in channel \(packet.channelID) for \(senderID) (\(channel.participantCount) total)")
            }
            return
        }

        // Encode the packet once.
        var outBuffer = context.channel.allocator.buffer(capacity: kPacketHeaderSize + packet.payload.count + kPacketCRCSize)
        PacketCodec.encode(packet: packet, buffer: &outBuffer)

        for recipient in recipients {
            let envelope = AddressedEnvelope(remoteAddress: recipient.remoteAddress, data: outBuffer)
            context.write(NIOAny(envelope), promise: nil)
        }
        context.flush()

        totalForwarded += recipients.count
        // Log first forward and every 100th.
        if totalForwarded <= recipients.count {
            logger.info("First forward: \(packet.type) from \(senderID) → \(recipients.count) recipient(s) at \(recipients.map { "\($0.remoteAddress)" })")
        } else if totalForwarded % 100 < recipients.count {
            logger.info("Forwarded \(totalForwarded) packets total (\(channel.participantCount) participants in channel)")
        }
    }

    // MARK: - Cleanup

    /// Sweep all channels, remove stale participants, and delete empty channels.
    public func cleanupStaleParticipants() {
        var emptyChannelIDs: [UUID] = []

        for (channelID, channel) in channels {
            let removed = channel.removeStaleParticipants(timeout: config.heartbeatTimeout)
            for id in removed {
                logger.info("Evicted stale participant \(id) from channel \(channelID)")
            }
            if channel.participantCount == 0 {
                emptyChannelIDs.append(channelID)
            }
        }

        for channelID in emptyChannelIDs {
            removeChannel(id: channelID)
        }
    }
}
