// Based on LocalDevVPN, Copyright (c) 2025 SideStore Team.
// See LICENSE-LocalDevVPN and README.md for attribution and modifications.
import Foundation

enum LocalVPNPacket {
    static func address(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    /// Reflect only IPv4 traffic between our two addresses. Swapping both addresses
    /// preserves the IPv4 header and TCP/UDP pseudo-header checksums, including fragments.
    static func reflect(_ packet: Data, device: [UInt8], peer: [UInt8]) -> Data? {
        guard device.count == 4, peer.count == 4, packet.count >= 20 else { return nil }
        var bytes = [UInt8](packet)
        let headerLength = Int(bytes[0] & 0x0f) * 4
        let totalLength = Int(bytes[2]) * 256 + Int(bytes[3])
        guard bytes[0] >> 4 == 4, headerLength >= 20, totalLength >= headerLength,
              totalLength <= bytes.count, Array(bytes[12..<16]) == device,
              Array(bytes[16..<20]) == peer else { return nil }
        bytes.replaceSubrange(12..<16, with: peer)
        bytes.replaceSubrange(16..<20, with: device)
        return Data(bytes)
    }
}
