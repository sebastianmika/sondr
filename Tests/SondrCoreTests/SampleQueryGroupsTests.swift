import GRDB
import Testing

@testable import SondrCore

/// Samples 1-4 are one group (C3, E3, G3, C4; representative 3), 5 and 6 are single samples.
private func makeLibrary() throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
        let names = ["Piano_C3", "Piano_E3", "Piano_G3", "Piano_C4", "Kick_Hard", "Snare_Soft"]
        let pitches: [(Int, String)?] = [(48, "C3"), (52, "E3"), (55, "G3"), (60, "C4"), nil, nil]
        for (index, name) in names.enumerated() {
            let id = Int64(index + 1)
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, ?, ?, 1, 48000, 1, 'wav', 1, 0, 0)
                    """, arguments: [id, "h\(id)", "/lib/\(name).wav", "\(name).wav", "\(name).wav"])
        }
        try db.execute(sql: "INSERT INTO sample_groups (id, location_id, folder, key, name, representative_id) VALUES (1, 1, '', 'piano_{p}', 'Piano', 3)")
        for (index, pitch) in pitches.enumerated() {
            guard let pitch else { continue }
            try db.execute(
                sql: "UPDATE samples SET group_id = 1, pitch = ?, pitch_label = ? WHERE id = ?",
                arguments: [pitch.0, pitch.1, index + 1])
        }
    }
    return database
}

private func browse(_ database: LibraryDatabase, keyword: String = "", collapse: Bool) throws -> SamplePage {
    var filter = SampleFilter()
    filter.keyword = keyword
    return try database.writer.read { try SampleQuery.browse($0, filter: filter, collapseGroups: collapse) }
}

@Test func browseShowsEveryMemberUnlessGroupsAreCollapsed() throws {
    let database = try makeLibrary()
    #expect(try browse(database, collapse: false).total == 6)
    let page = try browse(database, collapse: true)
    #expect(page.total == 3)
    #expect(page.rows.map(\.filename) == ["Kick_Hard.wav", "Piano_G3.wav", "Snare_Soft.wav"])
}

@Test func collapsedRowCarriesTheGroupInfo() throws {
    let database = try makeLibrary()
    let rows = try browse(database, collapse: true).rows
    let info = try #require(rows[1].multisample)
    #expect(info == MultisampleInfo(groupID: 1, groupName: "Piano", size: 4, lowLabel: "C3", highLabel: "C4", pitch: 55, pitchLabel: "G3", tags: [], clusters: []))
    #expect(rows[0].multisample == nil)
}

@Test func collapsedGroupShowsAMatchingMemberWhenTheRepresentativeDoesNotMatch() throws {
    let database = try makeLibrary()
    let page = try browse(database, keyword: "C4", collapse: true)
    #expect(page.rows.map(\.filename) == ["Piano_C4.wav"])
    #expect(page.total == 1)
    #expect(page.rows[0].multisample?.size == 4)
    #expect(try browse(database, keyword: "Piano", collapse: true).rows.map(\.filename) == ["Piano_G3.wav"])
    #expect(try browse(database, keyword: "Piano", collapse: false).total == 4)
}

@Test func collapsedPagingKeepsTotalAndOrder() throws {
    let database = try makeLibrary()
    let second = try database.writer.read {
        try SampleQuery.browse($0, filter: SampleFilter(), offset: 1, limit: 1, collapseGroups: true)
    }
    #expect(second.total == 3)
    #expect(second.rows.map(\.filename) == ["Piano_G3.wav"])
}

@Test func membersListsAGroupInPitchOrder() throws {
    let database = try makeLibrary()
    let members = try database.writer.read { try SampleQuery.members($0, groupID: 1) }
    #expect(members.map(\.multisample?.pitchLabel) == ["C3", "E3", "G3", "C4"])
}


/// Clusters 1 and 2 exist; `assignments` gives (sample id, cluster id, score).
private func assign(_ database: LibraryDatabase, _ assignments: [(Int64, Int, Double)]) throws {
    try database.writer.write { db in
        try db.execute(sql: "INSERT OR IGNORE INTO clusters (id, name) VALUES (1, 'bass'), (2, 'leads')")
        for (id, cluster, score) in assignments {
            try db.execute(
                sql: "UPDATE samples SET cluster_id = ?, cluster_score = ? WHERE id = ?", arguments: [cluster, score, id])
        }
    }
}

private func browse(_ database: LibraryDatabase, cluster: SampleFilter.ClusterChoice, collapse: Bool) throws -> SamplePage {
    var filter = SampleFilter()
    filter.cluster = cluster
    return try database.writer.read { try SampleQuery.browse($0, filter: filter, collapseGroups: collapse) }
}

@Test func groupRowListsTheDistinctSortedClustersAndTagsOfAllMembers() throws {
    let database = try makeLibrary()
    // Members: bass, bass, lead, weak lead (does not count).
    try assign(database, [(1, 1, 0.9), (2, 1, 0.9), (3, 2, 0.9), (4, 2, 0.1)])
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO tags (id, name) VALUES (1, 'warm'), (2, 'soft')")
        try db.execute(sql: "INSERT INTO sample_tags (sample_id, tag_id, source) VALUES (1, 1, 'auto'), (2, 1, 'auto'), (4, 2, 'auto')")
    }
    let info = try #require(try browse(database, collapse: true).rows[1].multisample)
    #expect(info.clusters == [1, 2])
    #expect(info.tags == ["soft", "warm"])
    #expect(info.groupName == "Piano")
}

@Test func collapsedClusterFilterTakesAGroupWhenAnyMemberMatches() throws {
    let database = try makeLibrary()
    // Group: three bass members and one lead. Singles: Kick is a lead, Snare is bass.
    try assign(database, [(1, 1, 0.9), (2, 1, 0.9), (3, 1, 0.9), (4, 2, 0.9), (5, 2, 0.9), (6, 1, 0.9)])

    #expect(try browse(database, cluster: .cluster(1), collapse: true).rows.map(\.filename) == ["Piano_G3.wav", "Snare_Soft.wav"])
    // The lone lead member brings the group into "leads", shown as that member.
    let leads = try browse(database, cluster: .cluster(2), collapse: true)
    #expect(leads.rows.map(\.filename) == ["Kick_Hard.wav", "Piano_C4.wav"])
    #expect(leads.total == 2)
    // Flat, every sample counts for itself.
    #expect(try browse(database, cluster: .cluster(2), collapse: false).rows.map(\.filename) == ["Kick_Hard.wav", "Piano_C4.wav"])
}

@Test func collapsedUnsortedFilterTakesAGroupWithAnUnsortedMember() throws {
    let database = try makeLibrary()
    try assign(database, [(1, 1, 0.9), (2, 1, 0.9), (3, 2, 0.9), (4, 1, 0.9), (5, 2, 0.9), (6, 1, 0.1)])
    #expect(try browse(database, cluster: .unsorted, collapse: true).rows.map(\.filename) == ["Snare_Soft.wav"])
    try assign(database, [(1, 1, 0.1)])
    #expect(try browse(database, cluster: .unsorted, collapse: true).rows.map(\.filename) == ["Piano_C3.wav", "Snare_Soft.wav"])
}

@Test func collapsedRowNameAndNameSortUseTheGroupName() throws {
    let database = try makeLibrary()
    try database.writer.write { try $0.execute(sql: "UPDATE sample_groups SET name = 'Zeta pad'") }
    let page = try browse(database, collapse: true)
    #expect(page.rows.map(\.name) == ["Kick_Hard.wav", "Snare_Soft.wav", "Zeta pad"])
    let flat = try browse(database, collapse: false)
    #expect(flat.rows.map(\.name).contains("Piano_G3.wav"))
}

@Test func membersFlagWhichOnesMatchTheFilter() throws {
    let database = try makeLibrary()
    var filter = SampleFilter()
    filter.keyword = "E3"
    let members = try database.writer.read { try SampleQuery.members($0, groupID: 1, filter: filter) }
    #expect(members.map(\.multisample?.matches) == [false, true, false, false])
    let all = try database.writer.read { try SampleQuery.members($0, groupID: 1) }
    #expect(all.allSatisfy { $0.multisample?.matches == true })
}

@Test func sampleIDsWithCollapseReturnsOneRowPerGroupWithAMatchingMember() throws {
    let database = try makeLibrary()
    var filter = SampleFilter()
    filter.sampleIDs = [1, 2, 4, 5]  // three of the four piano members, plus Kick
    let page = try database.writer.read { try SampleQuery.browse($0, filter: filter, collapseGroups: true) }
    #expect(page.total == 2)
    #expect(page.rows.map(\.filename) == ["Kick_Hard.wav", "Piano_C3.wav"])
    #expect(page.rows.allSatisfy { filter.sampleIDs!.contains($0.id) })
}
