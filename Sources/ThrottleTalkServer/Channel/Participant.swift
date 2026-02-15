import Foundation
import NIOCore

/// A single participant connected to a voice channel.
///
/// Participants are identified by UUID and tracked by their UDP source address.
/// The server uses heartbeat timestamps to detect and evict stale participants.
public struct Participant {
    /// Unique identifier for this participant.
    public let id: UUID

    /// The most recent UDP source address seen for this participant.
    public var remoteAddress: SocketAddress

    /// Timestamp of the last heartbeat received from this participant.
    public private(set) var lastHeartbeat: Date

    /// Current flag state (VOX, muted, admin).
    public var flags: PacketFlags

    /// Rate limiting: number of packets received in the current 1-second window.
    public var packetCountInWindow: Int = 0

    /// Start time of the current rate-limit window.
    public var rateLimitWindowStart: Date = Date()

    /// Maximum packets per second allowed from a single participant.
    public static let maxPacketsPerSecond = 60

    /// Create a new participant.
    public init(
        id: UUID,
        remoteAddress: SocketAddress,
        flags: PacketFlags = []
    ) {
        self.id = id
        self.remoteAddress = remoteAddress
        self.lastHeartbeat = Date()
        self.flags = flags
    }

    /// Whether this participant is still considered alive given the specified timeout.
    public func isAlive(timeout: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastHeartbeat) < timeout
    }

    /// Record that a heartbeat was received right now.
    public mutating func updateHeartbeat() {
        lastHeartbeat = Date()
    }

    /// Check if this participant is within rate limits. Returns `true` if allowed.
    /// Resets the window if it has elapsed.
    public mutating func checkRateLimit() -> Bool {
        let now = Date()
        if now.timeIntervalSince(rateLimitWindowStart) >= 1.0 {
            // New window.
            rateLimitWindowStart = now
            packetCountInWindow = 1
            return true
        }
        packetCountInWindow += 1
        return packetCountInWindow <= Self.maxPacketsPerSecond
    }
}
