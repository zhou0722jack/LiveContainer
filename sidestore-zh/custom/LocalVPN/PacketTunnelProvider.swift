// Based on SiamSadik/LocalDevVPN at 1b9ff7a2d79b4208919bb291f0c693b8cfabb6a5.
// Copyright (c) 2025 SideStore Team. See LICENSE-LocalDevVPN.
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var device: [UInt8] = []
    private var peer: [UInt8] = []
    private let stateLock = NSLock()
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let deviceIP = config["TunnelDeviceIP"] as? String ?? "10.7.0.0"
        let peerIP = config["TunnelFakeIP"] as? String ?? "10.7.0.1"
        guard let device = LocalVPNPacket.address(deviceIP), let peer = LocalVPNPacket.address(peerIP), device != peer else {
            completionHandler(NSError(domain: "SideStore.LocalVPN", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel IPv4 addresses"]))
            return
        }
        self.device = device
        self.peer = peer
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerIP)
        // Preserve SiamSadik's /32 fix: no implicit on-link route for the LAN.
        let ipv4 = NEIPv4Settings(addresses: [deviceIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peerIP, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { error in
            if let error { completionHandler(error); return }
            self.stateLock.lock()
            self.running = true
            self.stateLock.unlock()
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stateLock.lock()
        running = false
        stateLock.unlock()
        completionHandler()
    }

    private func readPackets() {
        stateLock.lock()
        let active = running
        stateLock.unlock()
        guard active else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.running
            self.stateLock.unlock()
            guard active else { return }
            var reflected: [Data] = []
            var families: [NSNumber] = []
            for (packet, family) in zip(packets, protocols) where family.int32Value == AF_INET {
                if let result = LocalVPNPacket.reflect(packet, device: self.device, peer: self.peer) {
                    reflected.append(result)
                    families.append(family)
                }
            }
            if !reflected.isEmpty { self.packetFlow.writePackets(reflected, withProtocols: families) }
            self.readPackets()
        }
    }
}
