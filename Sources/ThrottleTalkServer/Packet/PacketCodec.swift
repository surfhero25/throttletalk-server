import Foundation
import NIOCore

/// Encodes and decodes TTLK packets to/from NIO `ByteBuffer`.
public enum PacketCodec {

    // MARK: - Decode

    /// Attempt to decode a `Packet` from the front of `buffer`.
    ///
    /// Returns `nil` if the buffer is too short, the magic bytes don't match,
    /// the version is unsupported, the packet type is unknown, or the CRC32
    /// integrity check fails.
    public static func decode(buffer: inout ByteBuffer) -> Packet? {
        // Minimum readable: header (50) + CRC (4), payload may be 0-length.
        guard buffer.readableBytes >= kPacketHeaderSize + kPacketCRCSize else {
            return nil
        }

        // Snapshot the reader index so we can compute CRC over the entire
        // packet (header + payload) before the trailing CRC field.
        let startReaderIndex = buffer.readerIndex

        // --- Magic (4 bytes) ---
        guard let magic = buffer.readInteger(as: UInt32.self),
              magic == kPacketMagic else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Version (1 byte) ---
        guard let version = buffer.readInteger(as: UInt8.self),
              version == kPacketVersion else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Packet Type (1 byte) ---
        guard let typeRaw = buffer.readInteger(as: UInt8.self),
              let packetType = PacketType(rawValue: typeRaw) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Sequence Number (4 bytes) ---
        guard let sequenceNumber = buffer.readInteger(as: UInt32.self) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Timestamp (4 bytes) ---
        guard let timestamp = buffer.readInteger(as: UInt32.self) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Channel ID (16 bytes) ---
        guard let channelID = readUUID(from: &buffer) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Participant ID (16 bytes) ---
        guard let participantID = readUUID(from: &buffer) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Flags (1 byte) ---
        guard let flagsByte = buffer.readInteger(as: UInt8.self) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }
        let flags = PacketFlags(rawValue: flagsByte)

        // --- Reserved (1 byte) ---
        guard let reserved = buffer.readInteger(as: UInt8.self) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Payload Length (2 bytes) ---
        guard let payloadLength = buffer.readInteger(as: UInt16.self) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // Reject oversized payloads (2KB max — real audio frames are ~200 bytes).
        guard payloadLength <= 2048 else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // Ensure the remaining buffer holds payload + CRC.
        guard buffer.readableBytes >= Int(payloadLength) + kPacketCRCSize else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // --- Payload (N bytes) ---
        let payload: Data
        if payloadLength > 0 {
            guard let payloadBytes = buffer.readBytes(length: Int(payloadLength)) else {
                buffer.moveReaderIndex(to: startReaderIndex)
                return nil
            }
            payload = Data(payloadBytes)
        } else {
            payload = Data()
        }

        // --- CRC32 (4 bytes) ---
        // IMPORTANT: We must read the CRC bytes BEFORE calling getBytes below,
        // but getBytes(at:) requires index >= readerIndex. Since all the read*
        // calls above advanced the readerIndex past startReaderIndex, we need
        // to temporarily move it back to access the header+payload for CRC.
        guard let receivedCRC = buffer.readInteger(as: UInt32.self) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        // Validate CRC over header + payload (everything before the CRC field).
        let crcDataLength = kPacketHeaderSize + Int(payloadLength)
        let afterCRCIndex = buffer.readerIndex
        buffer.moveReaderIndex(to: startReaderIndex)
        guard let crcData = buffer.getBytes(at: startReaderIndex, length: crcDataLength) else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }
        buffer.moveReaderIndex(to: afterCRCIndex)
        let computedCRC = CRC32.compute(Data(crcData))

        guard computedCRC == receivedCRC else {
            buffer.moveReaderIndex(to: startReaderIndex)
            return nil
        }

        return Packet(
            version: version,
            type: packetType,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            channelID: channelID,
            participantID: participantID,
            flags: flags,
            reserved: reserved,
            payload: payload
        )
    }

    // MARK: - Encode

    /// Encode a `Packet` into `buffer`, appending a trailing CRC32.
    public static func encode(packet: Packet, buffer: inout ByteBuffer) {
        let startWriterIndex = buffer.writerIndex

        // --- Header ---
        buffer.writeInteger(kPacketMagic)
        buffer.writeInteger(packet.version)
        buffer.writeInteger(packet.type.rawValue)
        buffer.writeInteger(packet.sequenceNumber)
        buffer.writeInteger(packet.timestamp)
        writeUUID(packet.channelID, to: &buffer)
        writeUUID(packet.participantID, to: &buffer)
        buffer.writeInteger(packet.flags.rawValue)
        buffer.writeInteger(packet.reserved)
        buffer.writeInteger(UInt16(packet.payload.count))

        // --- Payload ---
        if !packet.payload.isEmpty {
            buffer.writeBytes(packet.payload)
        }

        // --- CRC32 ---
        let bytesWritten = buffer.writerIndex - startWriterIndex
        let crcBytes = buffer.getBytes(at: startWriterIndex, length: bytesWritten)!
        let crc = CRC32.compute(Data(crcBytes))
        buffer.writeInteger(crc)
    }

    // MARK: - UUID Helpers

    /// Read a 16-byte UUID from the buffer in network byte order.
    private static func readUUID(from buffer: inout ByteBuffer) -> UUID? {
        guard let bytes = buffer.readBytes(length: 16) else { return nil }
        let uuid = UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid
    }

    /// Write a UUID as 16 raw bytes into the buffer.
    private static func writeUUID(_ uuid: UUID, to buffer: inout ByteBuffer) {
        let u = uuid.uuid
        buffer.writeBytes([
            u.0,  u.1,  u.2,  u.3,
            u.4,  u.5,  u.6,  u.7,
            u.8,  u.9,  u.10, u.11,
            u.12, u.13, u.14, u.15,
        ])
    }
}
