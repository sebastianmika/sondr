import Testing

@testable import SondrCore

@Test(arguments: [
    ("Piano_C3", 48, MultisampleNames.Kind.note, "piano_{p}"),
    ("Piano_C4", 60, .note, "piano_{p}"),
    ("Piano F#2", 42, .note, "piano {p}"),
    ("Piano-Db-1", 1, .note, "piano-{p}"),
    ("pad_c3", 48, .note, "pad_{p}"),
    ("Piano_61", 61, .number, "piano_{p}"),
    ("061_Piano", 61, .number, "{p}_piano"),
])
func parseFindsThePitchToken(stem: String, midi: Int, kind: MultisampleNames.Kind, key: String) throws {
    let parsed = try #require(MultisampleNames.parse(stem: stem))
    #expect(parsed.midi == midi)
    #expect(parsed.kind == kind)
    #expect(parsed.key == key)
}

@Test(arguments: ["Loop 120 bpm", "Loop_120bpm", "Cmin", "Kick", "Kick_200", "Pad_Warm", "Cat3gory"])
func parseIgnoresNamesWithoutAPitch(stem: String) {
    #expect(MultisampleNames.parse(stem: stem) == nil)
}

@Test func parseSeparatesLayerTokensFromTheKey() throws {
    let soft = try #require(MultisampleNames.parse(stem: "Piano_C3_v1"))
    let hard = try #require(MultisampleNames.parse(stem: "Piano_v2_C3"))
    #expect(soft.key == hard.key)
    #expect(soft.layer == "v1")
    #expect(hard.layer == "v2")
    #expect(try #require(MultisampleNames.parse(stem: "Piano_C3_rr3")).layer == "rr3")
}

@Test func noteLabelRoundTripsWithParse() throws {
    for midi in [0, 1, 36, 54, 60, 127] {
        let stem = "x_\(MultisampleNames.noteLabel(midi))"
        #expect(try #require(MultisampleNames.parse(stem: stem)).midi == midi)
    }
}

@Test func groupsNeedThreeDistinctPitchesInOneFolder() {
    let paths = [
        "Keys/Piano_C3.wav", "Keys/Piano_D3.wav", "Keys/Piano_E3.wav", "Keys/Piano_E3_v2.wav",
        "Keys/Rhodes_C3.wav", "Keys/Rhodes_D3.wav",
        "Other/Piano_C3.wav", "Other/Piano_D3.wav",
        "Drums/Kick 1.wav", "Drums/Kick 2.wav", "Drums/Kick 3.wav", "Drums/Kick 4.wav",
    ]
    let groups = MultisampleNames.groups(paths: paths)
    #expect(groups.map(\.folder) == ["Drums", "Keys"])
    let piano = groups[1]
    #expect(piano.key == "piano_{p}")
    #expect(piano.pitches == [48, 50, 52])
    #expect(piano.members.count == 4)
    #expect(groups[0].kind == .number)
}

@Test func groupsKeepVelocityLayerFoldersApart() {
    let paths = ["P/soft/Pno_C3.wav", "P/soft/Pno_D3.wav", "P/soft/Pno_E3.wav",
                 "P/loud/Pno_C3.wav", "P/loud/Pno_D3.wav", "P/loud/Pno_E3.wav"]
    #expect(MultisampleNames.groups(paths: paths).map(\.folder) == ["P/loud", "P/soft"])
}

@Test func numberGroupsNeedRootNotesThatMatchTheNumbers() throws {
    let paths = ["Pno_60.wav", "Pno_62.wav", "Pno_64.wav"]
    let numbers = try #require(MultisampleNames.groups(paths: paths).first)
    #expect(numbers.kind == .number)
    #expect(!MultisampleNames.isConfirmed(numbers, rootNote: { _ in nil }))
    #expect(MultisampleNames.isConfirmed(numbers, rootNote: { Int($0.dropFirst(4).prefix(2)) }))
    #expect(MultisampleNames.isConfirmed(numbers, rootNote: { Int($0.dropFirst(4).prefix(2)).map { $0 + 12 } }))
    #expect(!MultisampleNames.isConfirmed(numbers, rootNote: { Int($0.dropFirst(4).prefix(2)).map { $0 + 1 } }))
    #expect(!MultisampleNames.isConfirmed(numbers, rootNote: { $0.hasSuffix("60.wav") ? 60 : 48 }))
    #expect(!MultisampleNames.isConfirmed(numbers, rootNote: { $0.hasSuffix("64.wav") ? nil : Int($0.dropFirst(4).prefix(2)) }))
}

@Test func noteGroupsNeedNoConfirmation() throws {
    let group = try #require(MultisampleNames.groups(paths: ["P_C3.wav", "P_D3.wav", "P_E3.wav"]).first)
    #expect(MultisampleNames.isConfirmed(group, rootNote: { _ in nil }))
}

@Test func takeNumbersAfterANoteAreLayersNotPartOfTheKey() throws {
    let plain = try #require(MultisampleNames.parse(stem: "Mini_Bass_A#0"))
    let take = try #require(MultisampleNames.parse(stem: "Mini_Bass_A#0_0002"))
    #expect(take.key == plain.key)
    #expect(take.layer == "0002")
    #expect(take.midi == plain.midi)
    #expect(MultisampleNames.parse(stem: "Piano_061")?.kind == .number)
}

@Test func membersKeepTheNoteAsWrittenInTheFileName() throws {
    let group = try #require(MultisampleNames.groups(paths: ["P_c3.wav", "P_d#3.wav", "P_g3_0001.wav", "P_Bb3.wav"]).first)
    #expect(group.members.map(\.label) == ["C3", "D#3", "G3", "Bb3"])
}

@Test func parseDropsANumberThatIsAPitchOfTheFile() throws {
    let parsed = try #require(MultisampleNames.parse(stem: "45 Return Home Kawaii C2", pitchNumbers: { [45, 48, 51] }))
    #expect(parsed.key == "return home kawaii {p}")
    #expect(parsed.midi == 36)
    #expect(parsed.label == "C2")
}

@Test func parseKeepsTheNumberWithoutMatchingMetadata() throws {
    let without = try #require(MultisampleNames.parse(stem: "45 Return Home Kawaii C2"))
    let unrelated = try #require(MultisampleNames.parse(stem: "Kick 1 C3", pitchNumbers: { [60, 48, 63] }))
    #expect(without.key == "45 return home kawaii {p}")
    #expect(unrelated.key == "kick 1 {p}")
}

@Test func parseDropsAHyphenIdAfterTheNote() throws {
    let parsed = try #require(MultisampleNames.parse(stem: "KoolDix_SH101_C#2-ASAU"))
    #expect(parsed.key == "kooldix_sh101_{p}")
    #expect(parsed.midi == 37)
    #expect(parsed.layer == "ASAU")
}

@Test(arguments: ["Pad_C3-Soft", "Pad_C3-ASAU2", "Pad_C3-asau"])
func parseKeepsOtherTextAfterTheNote(stem: String) throws {
    let parsed = try #require(MultisampleNames.parse(stem: stem))
    #expect(parsed.key.hasPrefix("pad_{p}-"))
}

@Test func groupsJoinFilesWhoseNamesDifferOnlyByTheirOwnPitchNumbers() {
    let pitches = [0: 24, 28: 31, 34: 36, 45: 48]
    let paths = pitches.keys.sorted().map { "Voices/\($0) Return Home Kawaii \(MultisampleNames.noteLabel(pitches[$0]! + 12)).wav" }
    let lowNotes = Dictionary(uniqueKeysWithValues: pitches.keys.map { low in
        (paths.first { $0.contains("/\(low) ") }!, Set([low, pitches[low]!]))
    })

    #expect(MultisampleNames.groups(paths: paths).isEmpty)
    let groups = MultisampleNames.groups(paths: paths) { lowNotes[$0] ?? [] }
    #expect(groups.count == 1)
    #expect(groups.first?.members.count == 4)
    #expect(groups.first?.key == "return home kawaii {p}")
}

@Test func parseDropsALeadingNumberThatIsTheNotesMidiNumberUpToOctaves() throws {
    let low = try #require(MultisampleNames.parse(stem: "61 Violin Mirage C#3"))
    let high = try #require(MultisampleNames.parse(stem: "62 Violin Mirage D3"))
    #expect(low.key == "violin mirage {p}")
    #expect(low.key == high.key)
}

@Test func parseKeepsALeadingNumberThatIsNotThePitch() throws {
    let parsed = try #require(MultisampleNames.parse(stem: "2 Kick C3"))
    #expect(parsed.key == "2 kick {p}")
}

@Test func tempoSeriesWithoutRootNotesAreNotMultisamples() {
    let paths = ["075", "090", "100", "110", "120"].map { "Breaks/\($0) Service Vinyl Breaks.wav" }
    let group = MultisampleNames.groups(paths: paths)
    #expect(group.count == 1)
    #expect(!MultisampleNames.isBackedByMetadata(group[0], rootNotes: Array(repeating: nil, count: paths.count)))
}
