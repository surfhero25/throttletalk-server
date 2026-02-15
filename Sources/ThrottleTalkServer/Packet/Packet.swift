import Foundation

// MARK: - Constants

/// Magic bytes identifying a TTLK packet: ASCII "TTLK".
public let kPacketMagic: UInt32 = 0x54544C4B

/// Current protocol version.
public let kPacketVersion: UInt8 = 0x01

/// Fixed header size in bytes (everything before the variable-length payload).
public let kPacketHeaderSize: Int = 50

/// Size of the trailing CRC32 field.
public let kPacketCRCSize: Int = 4

// MARK: - PacketType

/// Discriminator for the three packet types in the TTLK protocol.
public enum PacketType: UInt8 {
    case audio     = 0x01
    case control   = 0x02
    case heartbeat = 0x03
}

// MARK: - PacketFlags

/// Bit-field flags carried in every TTLK packet.
public struct PacketFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Voice-activity detection is currently triggering.
    public static let voxActive = PacketFlags(rawValue: 1 << 0)
    /// Participant has self-muted.
    public static let muted     = PacketFlags(rawValue: 1 << 1)
    /// Participant has admin privileges on this channel.
    public static let admin     = PacketFlags(rawValue: 1 << 2)
}

// MARK: - Packet

/// A decoded TTLK protocol packet.
public struct Packet {
    public let version: UInt8
    public let type: PacketType
    public let sequenceNumber: UInt32
    public let timestamp: UInt32
    public let channelID: UUID
    public let participantID: UUID
    public let flags: PacketFlags
    public let reserved: UInt8
    public let payload: Data

    public init(
        version: UInt8 = kPacketVersion,
        type: PacketType,
        sequenceNumber: UInt32,
        timestamp: UInt32,
        channelID: UUID,
        participantID: UUID,
        flags: PacketFlags,
        reserved: UInt8 = 0,
        payload: Data = Data()
    ) {
        self.version = version
        self.type = type
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.channelID = channelID
        self.participantID = participantID
        self.flags = flags
        self.reserved = reserved
        self.payload = payload
    }
}

// MARK: - CRC32

/// CRC32 (ISO 3309 / ITU-T V.42) used for packet integrity checks.
enum CRC32 {

    /// Standard CRC32 lookup table.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    /// Compute CRC32 over raw bytes.
    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Compute CRC32 over a contiguous byte buffer.
    static func compute(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for i in 0..<bytes.count {
            let byte = bytes[i]
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}
