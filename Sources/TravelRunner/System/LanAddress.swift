import Darwin
import Foundation

/// The address that a phone on the same network uses to reach this Mac.
struct LanAddress: Equatable, Sendable {
    /// The network interface, such as `en0` or `en7`.
    var interface: String
    /// The IPv4 address of the interface.
    var ip: String

    /// What the LAN toggle shows, such as "en7 · 10.0.1.23".
    var label: String { "\(interface) · \(ip)" }

    /// One IPv4 address of an interface that is up.
    struct InterfaceAddress: Equatable, Sendable {
        var interface: String
        var ip: String
    }

    /// The address of the interface that carries the default route. It is not
    /// always `en0`: a USB or Thunderbolt adapter is `en5` or higher. Nil when
    /// the Mac has no LAN address.
    static func current() async -> LanAddress? {
        let route = await Shell.execute("/sbin/route", ["-n", "get", "default"], timeout: .seconds(5))
        let defaultInterface = route.succeeded ? defaultInterface(fromRouteOutput: route.stdout) : nil
        return pick(defaultInterface: defaultInterface, from: interfaceAddresses())
    }

    /// The interface in the output of `route -n get default`.
    static func defaultInterface(fromRouteOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The address to use. It is the one of the default-route interface. When a
    /// VPN tunnel carries the default route, its address is not on the LAN, so
    /// the first Ethernet or Wi-Fi interface (`en*`) with an address is used.
    static func pick(defaultInterface: String?, from addresses: [InterfaceAddress]) -> LanAddress? {
        let usable = addresses.filter { !$0.ip.hasPrefix("127.") && !$0.ip.hasPrefix("169.254.") }
        if let name = defaultInterface, !isTunnel(name), let match = usable.first(where: { $0.interface == name }) {
            return LanAddress(interface: match.interface, ip: match.ip)
        }
        guard let fallback = usable.first(where: { $0.interface.hasPrefix("en") }) else { return nil }
        return LanAddress(interface: fallback.interface, ip: fallback.ip)
    }

    private static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"].contains { name.hasPrefix($0) }
    }

    /// The IPv4 addresses of the interfaces that are up and running, in system order.
    static func interfaceAddresses() -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [InterfaceAddress] = []
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            result.append(InterfaceAddress(
                interface: String(cString: entry.pointee.ifa_name),
                ip: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ))
        }
        return result
    }
}
