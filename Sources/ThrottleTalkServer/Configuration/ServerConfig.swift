import Foundation

/// Configuration for the ThrottleTalk UDP relay server.
public struct ServerConfig {
    /// The UDP port to bind on.
    public let port: UInt16

    /// Maximum number of concurrent voice channels.
    public let maxChannels: Int

    /// Maximum participants allowed in a single channel.
    public let maxParticipantsPerChannel: Int

    /// Duration in seconds after which a participant with no heartbeat is considered dead.
    public let heartbeatTimeout: TimeInterval

    /// Interval in seconds between heartbeat cleanup sweeps.
    public let heartbeatInterval: TimeInterval

    public init(
        port: UInt16 = 9000,
        maxChannels: Int = 100,
        maxParticipantsPerChannel: Int = 40,
        heartbeatTimeout: TimeInterval = 10,
        heartbeatInterval: TimeInterval = 3
    ) {
        self.port = port
        self.maxChannels = maxChannels
        self.maxParticipantsPerChannel = maxParticipantsPerChannel
        self.heartbeatTimeout = heartbeatTimeout
        self.heartbeatInterval = heartbeatInterval
    }
}
