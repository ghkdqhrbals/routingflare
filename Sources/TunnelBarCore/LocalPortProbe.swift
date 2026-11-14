import Darwin

public enum LocalPortProbe {
    public static func isListening(_ port: Int, timeoutMilliseconds: Int32 = 300) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&event, 1, max(0, timeoutMilliseconds)) > 0 else { return false }

        var socketError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 && socketError == 0
    }
}

public enum LocalPortAvailabilitySummary: Equatable {
    case ready
    case checking
    case closed

    public static func summarize(ports: [Int], availability: [Int: Bool]) -> Self {
        if ports.contains(where: { availability[$0] == false }) { return .closed }
        if ports.contains(where: { availability[$0] == nil }) { return .checking }
        return .ready
    }
}
