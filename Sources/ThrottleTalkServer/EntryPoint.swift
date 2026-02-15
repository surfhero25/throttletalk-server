import Foundation
import ArgumentParser
import Logging

/// CLI entry point for the ThrottleTalk UDP relay server.
@main
struct ThrottleTalkServerCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "throttletalk-server",
        abstract: "ThrottleTalk SFU relay server for motorcycle group voice chat."
    )

    @Option(name: .long, help: "Host address to bind to. (env: THROTTLETALK_HOST)")
    var host: String = ProcessInfo.processInfo.environment["THROTTLETALK_HOST"] ?? "0.0.0.0"

    @Option(name: .long, help: "UDP port to listen on. (env: THROTTLETALK_PORT)")
    var port: UInt16 = UInt16(ProcessInfo.processInfo.environment["THROTTLETALK_PORT"] ?? "") ?? 9000

    @Option(name: .long, help: "Maximum number of concurrent voice channels. (env: THROTTLETALK_MAX_CHANNELS)")
    var maxChannels: Int = Int(ProcessInfo.processInfo.environment["THROTTLETALK_MAX_CHANNELS"] ?? "") ?? 100

    @Option(name: .long, help: "Maximum participants per voice channel. (env: THROTTLETALK_MAX_PARTICIPANTS)")
    var maxParticipants: Int = Int(ProcessInfo.processInfo.environment["THROTTLETALK_MAX_PARTICIPANTS"] ?? "") ?? 40

    @Option(name: .long, help: "Seconds before a participant with no heartbeat is evicted. (env: THROTTLETALK_HEARTBEAT_TIMEOUT)")
    var heartbeatTimeout: Double = Double(ProcessInfo.processInfo.environment["THROTTLETALK_HEARTBEAT_TIMEOUT"] ?? "") ?? 10

    @Option(name: .long, help: "Seconds between heartbeat cleanup sweeps. (env: THROTTLETALK_HEARTBEAT_INTERVAL)")
    var heartbeatInterval: Double = Double(ProcessInfo.processInfo.environment["THROTTLETALK_HEARTBEAT_INTERVAL"] ?? "") ?? 3

    func run() throws {
        // Bootstrap swift-log.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }
        let logger = Logger(label: "com.throttletalk.server")

        let config = ServerConfig(
            port: port,
            maxChannels: maxChannels,
            maxParticipantsPerChannel: maxParticipants,
            heartbeatTimeout: heartbeatTimeout,
            heartbeatInterval: heartbeatInterval
        )

        let server = UDPServer(config: config, logger: logger)
        try server.start()

        logger.info("ThrottleTalk relay server is running. Press Ctrl+C to stop.")

        // Install signal handlers for graceful shutdown (SIGINT for Ctrl+C, SIGTERM for Docker).
        func installSignalHandler(sig: Int32, name: String) {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            signal(sig, SIG_IGN)
            source.setEventHandler {
                logger.info("Received \(name), shutting down...")
                do {
                    try server.stop()
                } catch {
                    logger.error("Error during shutdown: \(error)")
                }
                Foundation.exit(0)
            }
            source.resume()
        }

        installSignalHandler(sig: SIGINT, name: "SIGINT")
        installSignalHandler(sig: SIGTERM, name: "SIGTERM")

        // Keep the process alive on the main run loop.
        dispatchMain()
    }
}
