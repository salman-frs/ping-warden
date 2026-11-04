//
//  ICMPEcho.swift
//  PingWarden
//
//  ICMP echo requests and replies for the router probe. macOS lets an
//  unprivileged process exchange them over a SOCK_DGRAM ICMP socket, the
//  way /sbin/ping does, so no helper or root is involved.
//

import Foundation

enum ICMPEcho {
    struct Reply: Equatable, Sendable {
        let identifier: UInt16
        let sequence: UInt16
    }

    private static let echoRequestType: UInt8 = 8
    private static let echoReplyType: UInt8 = 0
    private static let headerSize = 8

    static func request(identifier: UInt16, sequence: UInt16, payloadSize: Int = 16) -> [UInt8] {
        var packet: [UInt8] = [
            echoRequestType, 0,
            0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xff),
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
        ]
        packet += [UInt8](repeating: 0, count: payloadSize)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        return packet
    }

    /// The echo reply in a received datagram, or nil for anything else.
    /// macOS puts the IPv4 header in front of it; Linux does not.
    static func reply(in datagram: [UInt8]) -> Reply? {
        var offset = 0
        if let first = datagram.first, first >> 4 == 4 {
            offset = Int(first & 0x0f) * 4
        }
        guard datagram.count >= offset + headerSize,
              datagram[offset] == echoReplyType,
              datagram[offset + 1] == 0 else {
            return nil
        }
        return Reply(
            identifier: UInt16(datagram[offset + 4]) << 8 | UInt16(datagram[offset + 5]),
            sequence: UInt16(datagram[offset + 6]) << 8 | UInt16(datagram[offset + 7])
        )
    }

    /// The RFC 1071 Internet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}
