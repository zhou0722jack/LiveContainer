import Foundation

@main
struct LocalVPNPacketTests {
    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: data.count, by: 2) {
            sum += UInt32(data[i]) << 8
            if i + 1 < data.count { sum += UInt32(data[i + 1]) }
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func main() {
        let device = LocalVPNPacket.address("10.7.0.0")!
        let peer = LocalVPNPacket.address("10.7.0.1")!
        for invalid in ["10.7.0", "256.1.1.1", "a.0.0.1", "1..0.1", ""] {
            precondition(LocalVPNPacket.address(invalid) == nil)
        }
        // Include an IPv4 option and odd-length payload to exercise packet boundaries.
        var packet: [UInt8] = [0x46, 0, 0, 37, 0, 1, 0, 0, 64, 17, 0, 0] + device + peer
        packet += [1, 1, 1, 1] + [0x12, 0x34, 0x56, 0x78, 0, 13, 0, 0] + [1, 2, 3, 4, 5]
        let headerSum = checksum(Array(packet[0..<24]))
        packet[10] = UInt8(headerSum >> 8); packet[11] = UInt8(headerSum & 255)
        let pseudo: [UInt8] = device + peer + [0, 17, 0, 13]
        let udpSum = checksum(pseudo + Array(packet[24...]))
        packet[30] = UInt8(udpSum >> 8); packet[31] = UInt8(udpSum & 255)
        let reflected = [UInt8](LocalVPNPacket.reflect(Data(packet), device: device, peer: peer)!)
        precondition(Array(reflected[12..<16]) == peer && Array(reflected[16..<20]) == device)
        precondition(checksum(Array(reflected[0..<24])) == 0)
        precondition(checksum(peer + device + [0, 17, 0, 13] + Array(reflected[24...])) == 0)
        precondition(Array(reflected[20...]) == Array(packet[20...]))
        precondition(LocalVPNPacket.reflect(Data(reflected), device: device, peer: peer) == nil)
        precondition(LocalVPNPacket.reflect(Data(packet.prefix(19)), device: device, peer: peer) == nil)
        precondition(LocalVPNPacket.reflect(Data(packet.dropLast()), device: device, peer: peer) == nil)
        var wrongVersion = packet; wrongVersion[0] = 0x66
        precondition(LocalVPNPacket.reflect(Data(wrongVersion), device: device, peer: peer) == nil)
        var wrongIHL = packet; wrongIHL[0] = 0x44
        precondition(LocalVPNPacket.reflect(Data(wrongIHL), device: device, peer: peer) == nil)
        var fragment = packet; fragment[6] = 0x20
        precondition(LocalVPNPacket.reflect(Data(fragment), device: device, peer: peer) != nil)
        print("PASS: address validation, IPv4 reflection, UDP and IP checksums, options, fragments, unrelated traffic and truncation")
    }
}
