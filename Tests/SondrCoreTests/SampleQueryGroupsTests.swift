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
        try db.execute(sql: "INSERT INTO sample_groups (id, location_id, folder, key, representative_id) VALUES (1, 1, '', 'piano_{p}', 3)")
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
    #expect(info == MultisampleInfo(groupID: 1, size: 4, lowLabel: "C3", highLabel: "C4", pitch: 55, pitchLabel: "G3", clusterID: nil))
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
        // Stand-in for MultisampleGrouper.refreshClusters (agent E): most common sorted cluster, ties to the lower id.
        try db.execute(
            sql: """
                UPDATE sample_groups SET cluster_id = (
                    SELECT cluster_id FROM samples WHERE group_id = sample_groups.id AND cluster_score >= ?
                    GROUP BY cluster_id ORDER BY count(*) DESC, cluster_id LIMIT 1)
                """, arguments: [Double(ClusterAssigner.unsortedThreshold)])
    }
}

private func groupCluster(_ database: LibraryDatabase) throws -> Int? {
    try database.writer.read { try Int.fetchOne($0, sql: "SELECT cluster_id FROM sample_groups WHERE id = 1") }
}

private func browse(_ database: LibraryDatabase, cluster: SampleFilter.ClusterChoice, collapse: Bool) throws -> SamplePage {
    var filter = SampleFilter()
    filter.cluster = cluster
    return try database.writer.read { try SampleQuery.browse($0, filter: filter, collapseGroups: collapse) }
}

@Test func groupClusterIsTheMostCommonSortedClusterOfItsMembers() throws {
    let database = try makeLibrary()
    try assign(database, [(1, 2, 0.9), (2, 1, 0.9), (3, 1, 0.9), (4, 1, 0.1)])
    #expect(try groupCluster(database) == 1)
    // 1 vs 2, one member each: the lower id wins. A weak member does not count.
    try assign(database, [(1, 2, 0.9), (2, 1, 0.9), (3, 2, 0.1), (4, 2, 0.1)])
    #expect(try groupCluster(database) == 1)
    try assign(database, [(1, 2, 0.1), (2, 1, 0.1), (3, 2, 0.1), (4, 2, 0.1)])
    #expect(try groupCluster(database) == nil)
}

@Test func collapsedClusterFilterListsGroupsByTheirOwnCluster() throws {
    let database = try makeLibrary()
    // Group: three bass members and one lead. Singles: Kick is a lead, Snare is bass.
    try assign(database, [(1, 1, 0.9), (2, 1, 0.9), (3, 1, 0.9), (4, 2, 0.9), (5, 2, 0.9), (6, 1, 0.9)])

    let bass = try browse(database, cluster: .cluster(1), collapse: true)
    #expect(bass.rows.map(\.filename) == ["Piano_G3.wav", "Snare_Soft.wav"])
    #expect(bass.total == 2)
    #expect(bass.rows[0].multisample?.clusterID == 1)

    // The lone lead member does not bring the group into "leads".
    let leads = try browse(database, cluster: .cluster(2), collapse: true)
    #expect(leads.rows.map(\.filename) == ["Kick_Hard.wav"])

    // Flat, every sample counts for itself.
    #expect(try browse(database, cluster: .cluster(2), collapse: false).rows.map(\.filename) == ["Kick_Hard.wav", "Piano_C4.wav"])
}

@Test func collapsedUnsortedFilterListsGroupsWithoutASortedMember() throws {
    let database = try makeLibrary()
    try assign(database, [(1, 1, 0.1), (2, 1, 0.1), (3, 2, 0.1), (4, 1, 0.1), (5, 2, 0.9), (6, 1, 0.1)])
    #expect(try browse(database, cluster: .unsorted, collapse: true).rows.map(\.filename) == ["Piano_G3.wav", "Snare_Soft.wav"])
    try assign(database, [(1, 1, 0.9)])
    #expect(try browse(database, cluster: .unsorted, collapse: true).rows.map(\.filename) == ["Snare_Soft.wav"])
}
