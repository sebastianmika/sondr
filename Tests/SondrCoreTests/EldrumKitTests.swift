import Testing

@testable import SondrCore

@Suite struct EldrumKitTests {
    @Test func roundTripKeepsNameAndSlots() throws {
        var kit = EldrumKit(name: "Test Kit")
        kit.slots[0] = "kick.wav"
        kit.slots[7] = "it's.wav"
        let parsed = try EldrumKit.parse(kit.render(comment: "sondr: x"))
        #expect(parsed == kit)
        #expect(!parsed.lossy)
    }

    @Test func nameOverLimitThrows() {
        let kit = EldrumKit(name: String(repeating: "a", count: 22))
        #expect(throws: EldrumError.self) { try kit.render() }
    }

    @Test func parseFlagsRoundRobinAsLossy() throws {
        var kit = EldrumKit(name: "RR")
        kit.slots[0] = "a.wav"
        let text = try kit.render() + "[[key-zones.velocity-layers.sample-slots]]\nsample = 'b.wav'\n"
        let parsed = try EldrumKit.parse(text)
        #expect(parsed.slots[0] == "a.wav")
        #expect(parsed.lossy)
    }

    @Test func parseRejectsOtherFiles() {
        #expect(throws: EldrumError.notAnEldrum) { try EldrumKit.parse("# ELEKTRON MULTI-SAMPLE MAPPING FORMAT\n") }
    }
}
