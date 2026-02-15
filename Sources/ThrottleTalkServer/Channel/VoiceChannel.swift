import Foundation
import NIOCore

/// A voice channel that groups participants for audio relay.
///
/// All participant mutations happen on the NIO event loop, so no additional
/// locking is required. The dictionary provides O(1) participant lookup.
public final class VoiceChannel {

    /// Unique identifier for this channel.
    public let id: UUID

    /// Map of participant ID to `Participant` for O(1) access.
    private(set) var participants: [UUID: Participant] = [:]

    /// Set of participant IDs that have identified themselves as admin via heartbeat.
    private(set) var adminParticipantIDs: Set<UUID> = []

    /// When this channel was first created.
    public let createdAt: Date

    public init(id: UUID) {
        self.id = id
        self.createdAt = Date()
    }

    /// Number of active participants in this channel.
    public var participantCount: Int {
        participants.count
    }

    /// Add a participant to the channel.
    ///
    /// If a participant with the same ID already exists it will be replaced.
    public func addParticipant(_ participant: Participant) {
        participants[participant.id] = participant
    }

    /// Remove a participant by ID.
    public func removeParticipant(id: UUID) {
        participants.removeValue(forKey: id)
    }

    /// Look up a participant by ID.
    public func participant(for id: UUID) -> Participant? {
        participants[id]
    }

    /// Update a participant's remote address, heartbeat, and flags.
    ///
    /// UDP clients may roam (NAT rebinding, network switch), so the server
    /// always uses the most recently seen source address.
    public func updateParticipant(id: UUID, address: SocketAddress, flags: PacketFlags? = nil) {
        participants[id]?.remoteAddress = address
        participants[id]?.updateHeartbeat()

        // Track admin status from heartbeat flags.
        if let flags, flags.contains(.admin) {
            adminParticipantIDs.insert(id)
            participants[id]?.flags = flags
        }
    }

    /// Check if a participant is a verified admin (claimed admin via heartbeat).
    public func isAdmin(_ participantID: UUID) -> Bool {
        adminParticipantIDs.contains(participantID)
    }

    /// Check rate limit for a participant. Returns `false` if the participant
    /// is sending too many packets (flooding).
    public func checkRateLimit(for participantID: UUID) -> Bool {
        return participants[participantID]?.checkRateLimit() ?? false
    }

    /// Return all participants except the one with the given ID.
    ///
    /// Used to build the forwarding list for SFU relay.
    public func allParticipants(except id: UUID) -> [Participant] {
        participants.values.filter { $0.id != id }
    }

    /// Remove participants whose last heartbeat exceeds `timeout` seconds.
    ///
    /// - Returns: The UUIDs of participants that were removed.
    @discardableResult
    public func removeStaleParticipants(timeout: TimeInterval) -> [UUID] {
        var removed: [UUID] = []
        for (id, participant) in participants {
            if !participant.isAlive(timeout: timeout) {
                participants.removeValue(forKey: id)
                removed.append(id)
            }
        }
        return removed
    }
}
