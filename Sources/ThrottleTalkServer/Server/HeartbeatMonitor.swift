import Foundation
import NIOCore
import Logging

/// Periodically sweeps all channels to evict participants that have stopped
/// sending heartbeats.
///
/// Runs as a `RepeatedTask` on a NIO `EventLoop`, keeping everything
/// single-threaded and lock-free.
public final class HeartbeatMonitor {

    private let channelManager: ChannelManager
    private let eventLoop: EventLoop
    private let logger: Logger
    private let interval: TimeAmount

    /// Handle to the scheduled repeated task (used for cancellation).
    private var scheduledTask: RepeatedTask?

    public init(
        channelManager: ChannelManager,
        eventLoop: EventLoop,
        interval: TimeInterval = 5,
        logger: Logger
    ) {
        self.channelManager = channelManager
        self.eventLoop = eventLoop
        self.interval = .seconds(Int64(interval))
        self.logger = logger
    }

    /// Begin the periodic cleanup sweep.
    public func start() {
        logger.info("HeartbeatMonitor started (interval: \(interval))")
        scheduledTask = eventLoop.scheduleRepeatedTask(
            initialDelay: interval,
            delay: interval
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.trace("HeartbeatMonitor sweep running")
            self.channelManager.cleanupStaleParticipants()
        }
    }

    /// Cancel the periodic task.
    public func stop() {
        scheduledTask?.cancel()
        scheduledTask = nil
        logger.info("HeartbeatMonitor stopped")
    }
}
