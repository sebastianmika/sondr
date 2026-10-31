import Foundation
import Testing

@testable import SondrCore

@Suite struct EldrumSidecarTests {
    @Test func roundTrip() throws {
        let sidecar = EldrumSidecar(slots: [.init(pad: 2, contentHash: "ab", originalPath: "/s/k.aif", filename: "k.wav")])
        #expect(try EldrumSidecar.decode(sidecar.json()) == sidecar)
    }

    @Test func newerVersionIsRejected() throws {
        var sidecar = EldrumSidecar(slots: [])
        sidecar.version = EldrumSidecar.currentVersion + 1
        let data = try sidecar.json()
        #expect(throws: EldrumSidecarError.newerVersion(2)) { try EldrumSidecar.decode(data) }
    }

    @Test func urlSitsNextToTheEldrum() {
        let url = EldrumSidecar.url(forEldrum: URL(fileURLWithPath: "/k/Kit/Kit.eldrum"))
        #expect(url.path == "/k/Kit/Kit.sondr.json")
    }
}
