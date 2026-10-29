import Foundation
import Testing
@testable import VoxClipCore

@Suite("Local server address", .timeLimit(.minutes(1)))
struct LocalServerAddressTests {
    @Test(arguments: ["", "http://127.0.0.1:11434", "http://127.0.0.1:1234/v1", "http://localhost:11434", "https://LOCALHOST",
                      "http://127.4.5.6:8080", "http://[::1]:11434", "http://[0:0:0:0:0:0:0:1]/"])
    func loopbackStaysOnThisMac(_ base: String) {
        #expect(LocalServerAddress.remoteHost(base) == nil)
    }

    @Test(arguments: [("http://192.168.1.20:11434", "192.168.1.20"), ("https://ollama.example.com/v1", "ollama.example.com"),
                      ("http://128.0.0.1:11434", "128.0.0.1"), ("http://localhost.example.com:1234", "localhost.example.com"),
                      ("http://[fe80::1]:11434", "fe80::1")])
    func otherHostsAreOnTheNetwork(_ base: String, _ host: String) {
        #expect(LocalServerAddress.remoteHost(base) == host)
    }

    @Test(arguments: ["http://", "http://["])
    func unreadableHostsNeverCountAsLoopback(_ base: String) {
        #expect(LocalServerAddress.remoteHost(base) != nil)
    }
}
