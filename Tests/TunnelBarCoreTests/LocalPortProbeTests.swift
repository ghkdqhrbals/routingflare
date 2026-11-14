import Darwin
import XCTest
@testable import TunnelBarCore

final class LocalPortProbeTests: XCTestCase {
    func testDetectsListeningAndClosedLoopbackPort() throws {
        var listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { if listener >= 0 { close(listener) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &size)
            }
        }
        XCTAssertEqual(named, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertFalse(LocalPortProbe.isListening(port))

        XCTAssertEqual(listen(listener, 1), 0)
        XCTAssertTrue(LocalPortProbe.isListening(port))

        close(listener)
        listener = -1
        XCTAssertFalse(LocalPortProbe.isListening(port))
    }

    func testRejectsInvalidPorts() {
        XCTAssertFalse(LocalPortProbe.isListening(0))
        XCTAssertFalse(LocalPortProbe.isListening(65536))
    }
}
