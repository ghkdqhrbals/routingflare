import Foundation

public enum IPAllowlistError: Error, Equatable, LocalizedError {
    case invalidEntry(String)
    case invalidPrefix(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEntry(let entry):
            return "Invalid IP allowlist entry: \(entry)"
        case .invalidPrefix(let entry):
            return "Invalid CIDR prefix in allowlist entry: \(entry)"
        }
    }
}

public struct IPAllowlist {
    private let ranges: [IPRange]

    public init(entries: [String]) throws {
        self.ranges = try entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(IPRange.parse)
    }

    public var isEmpty: Bool {
        ranges.isEmpty
    }

    public func allows(_ address: String) -> Bool {
        guard !ranges.isEmpty else {
            return true
        }
        guard let ip = IPAddress(address) else {
            return false
        }
        return ranges.contains { $0.contains(ip) }
    }
}

struct IPRange: Equatable {
    let address: IPAddress
    let prefixLength: Int

    static func parse(_ entry: String) throws -> IPRange {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let address = IPAddress(String(parts[0])) else {
            throw IPAllowlistError.invalidEntry(entry)
        }

        let prefixLength: Int
        if parts.count == 2 {
            guard let parsedPrefix = Int(parts[1]),
                  parsedPrefix >= 0,
                  parsedPrefix <= address.bitWidth else {
                throw IPAllowlistError.invalidPrefix(entry)
            }
            prefixLength = parsedPrefix
        } else {
            prefixLength = address.bitWidth
        }

        return IPRange(address: address, prefixLength: prefixLength)
    }

    func contains(_ candidate: IPAddress) -> Bool {
        guard candidate.version == address.version else {
            return false
        }
        let byteCount = prefixLength / 8
        let remainder = prefixLength % 8

        if byteCount > 0 && candidate.bytes.prefix(byteCount) != address.bytes.prefix(byteCount) {
            return false
        }
        guard remainder > 0 else {
            return true
        }
        let mask = UInt8(0xff << UInt8(8 - remainder))
        return candidate.bytes[byteCount] & mask == address.bytes[byteCount] & mask
    }
}

struct IPAddress: Equatable {
    enum Version {
        case ipv4
        case ipv6
    }

    let version: Version
    let bytes: [UInt8]

    var bitWidth: Int {
        bytes.count * 8
    }

    init?(_ string: String) {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, string, &ipv4) == 1 {
            self.version = .ipv4
            self.bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, string, &ipv6) == 1 {
            self.version = .ipv6
            self.bytes = withUnsafeBytes(of: ipv6.__u6_addr.__u6_addr8) { Array($0) }
            return
        }

        return nil
    }
}
