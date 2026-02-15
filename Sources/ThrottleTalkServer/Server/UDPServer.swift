import Foundation
import NIOCore
import NIOPosix
import Logging

/// The main UDP server that binds a datagram socket, installs the packet
/// handler pipeline, and manages the server lifecycle.
public final class UDPServer {

    private let config: ServerConfig
    private let group: MultiThreadedEventLoopGroup
    private let channelManager: ChannelManager
    private let logger: Logger

    /// The bound NIO datagram channel.
    private var channel: NIOCore.Channel?

    /// The heartbeat cleanup monitor.
    private var heartbeatMonitor: HeartbeatMonitor?

    public init(config: ServerConfig, logger: Logger) {
        self.config = config
        // Single-threaded is fine for a UDP SFU -- all work is non-blocking I/O.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channelManager = ChannelManager(config: config, logger: logger)
        self.logger = logger
    }

    /// Bind the UDP socket and start serving.
    ///
    /// This call blocks until the channel is bound and ready to receive packets.
    public func start() throws {
        let handler = PacketHandler(channelManager: channelManager, logger: logger)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let boundChannel = try bootstrap.bind(host: "0.0.0.0", port: Int(config.port)).wait()
        self.channel = boundChannel

        // Start heartbeat monitor on the channel's event loop.
        let monitor = HeartbeatMonitor(
            channelManager: channelManager,
            eventLoop: boundChannel.eventLoop,
            interval: config.heartbeatInterval,
            logger: logger
        )
        monitor.start()
        self.heartbeatMonitor = monitor

        logger.info("ThrottleTalk server started on port \(config.port)")
    }

    /// Gracefully shut down the server.
    public func stop() throws {
        heartbeatMonitor?.stop()
        heartbeatMonitor = nil

        try channel?.close().wait()
        channel = nil

        try group.syncShutdownGracefully()
        logger.info("ThrottleTalk server stopped")
    }
}
