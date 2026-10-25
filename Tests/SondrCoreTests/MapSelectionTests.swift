import Foundation
import GRDB
import Testing

@testable import SondrCore

@Test func aFilterByIDsKeepsOnlyThoseSamples() throws {
    let (database, ids) = try makeLibrary(samples: 20)
    let page = try database.writer.read { db -> SamplePage in
        var filter = SampleFilter()
        filter.sampleIDs = Set([ids[2], ids[5], ids[9]])
        return try SampleQuery.browse(db, filter: filter, limit: 100)
    }
    #expect(page.total == 3)
    #expect(Set(page.rows.map(\.id)) == Set([ids[2], ids[5], ids[9]]))
}

@Test func anEmptySetOfIDsMatchesNothingButNilMatchesEverything() throws {
    let (database, _) = try makeLibrary(samples: 8)
    let (none, all) = try database.writer.read { db -> (Int, Int) in
        var filter = SampleFilter()
        filter.sampleIDs = []
        let none = try SampleQuery.browse(db, filter: filter, limit: 10).total
        filter.sampleIDs = nil
        return (none, try SampleQuery.browse(db, filter: filter, limit: 10).total)
    }
    #expect(none == 0 && all == 8)
}

@Test func theIDFilterCombinesWithTheOtherFilters() throws {
    let (database, ids) = try makeLibrary(samples: 20)
    let total = try database.writer.read { db -> Int in
        var filter = SampleFilter()
        filter.sampleIDs = Set(ids.prefix(10))
        filter.keyword = "1"  // names are "<n>.wav", n = 0...19: of the first ten only "1.wav" has a 1
        return try SampleQuery.browse(db, filter: filter, limit: 100).total
    }
    #expect(total == 1)
}

@Test func aHugeIDFilterIsStillOneQuery() throws {
    let (database, ids) = try makeLibrary(samples: 5)
    let total = try database.writer.read { db -> Int in
        var filter = SampleFilter()
        var big = Set((1_000_000..<1_150_000).map(Int64.init))
        big.insert(ids[1])
        big.insert(ids[3])
        filter.sampleIDs = big
        return try SampleQuery.browse(db, filter: filter, limit: 100).total
    }
    #expect(total == 2)
}

@Test func aFilterWithIDsIsNotEmpty() {
    var filter = SampleFilter()
    #expect(filter.isEmpty)
    filter.sampleIDs = []
    #expect(!filter.isEmpty)
}
