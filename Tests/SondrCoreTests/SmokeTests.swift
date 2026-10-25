import Testing

@testable import SondrCore

@Test func packageBuilds() {
    #expect(String(describing: SondrCore.self) == "SondrCore")
}
