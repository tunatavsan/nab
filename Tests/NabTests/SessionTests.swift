import Foundation
import Testing

@testable import NabCore

@Suite("Capture sessions")
struct SessionTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, at offset: TimeInterval, session: String? = nil) -> Entry {
        var e = Entry(
            id: "youtube:\(id)", url: URL(string: "https://youtu.be/\(id)")!, addedAt: base.addingTimeInterval(offset))
        e.sessionID = session
        return e
    }

    @Test func legacyEntriesClusterByGap() {
        let groups = SessionGrouping.groups([
            entry("a", at: 0), entry("b", at: 100), entry("c", at: 1000), entry("d", at: 1200),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].entryIDs == ["youtube:d", "youtube:c"])
        #expect(groups[1].entryIDs == ["youtube:b", "youtube:a"])
        #expect(groups[1].id == "legacy-\(Int(base.timeIntervalSince1970))")
        #expect(groups[1].start == base)
        #expect(groups[1].end == base.addingTimeInterval(100))
    }

    @Test func gapExactlyAtLimitStaysTogether() {
        #expect(SessionGrouping.groups([entry("a", at: 0), entry("b", at: 300)]).count == 1)
        #expect(SessionGrouping.groups([entry("a", at: 0), entry("b", at: 301)]).count == 2)
    }

    @Test func explicitSessionsGroupByID() {
        let groups = SessionGrouping.groups([
            entry("a", at: 0, session: "s-1"), entry("b", at: 5000, session: "s-2"),
            entry("c", at: 10, session: "s-1"),
        ])
        #expect(groups.map(\.id) == ["s-2", "s-1"])
        #expect(groups[1].entryIDs == ["youtube:c", "youtube:a"])
    }

    @Test func mixedLegacyAndExplicit() {
        let groups = SessionGrouping.groups([
            entry("old", at: 0), entry("new", at: 9000, session: "s-9"), entry("old2", at: 50),
        ])
        #expect(groups.map(\.id) == ["s-9", "legacy-\(Int(base.timeIntervalSince1970))"])
        #expect(groups[1].entryIDs.count == 2)
    }

    @Test func newestGroupFirst() {
        let groups = SessionGrouping.groups([
            entry("a", at: 0, session: "s-1"), entry("b", at: 100, session: "s-2"), entry("c", at: 50),
        ])
        #expect(groups.map(\.end) == groups.map(\.end).sorted(by: >))
        #expect(groups.first?.id == "s-2")
    }

    @Test func emptyInputGivesNoGroups() {
        #expect(SessionGrouping.groups([]).isEmpty)
    }

    @Test func oldJSONWithoutSessionIDDecodes() throws {
        let json = #"{"id":"youtube:a","url":"https://youtu.be/a","addedAt":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Entry.self, from: Data(json.utf8))
        #expect(decoded.sessionID == nil)
        #expect(decoded.inTray == false)
    }

    @Test func sessionIDRoundTrips() throws {
        let encoder = JSONEncoder()
        let original = entry("a", at: 0, session: "s-7")
        let back = try JSONDecoder().decode(Entry.self, from: try encoder.encode(original))
        #expect(back.sessionID == "s-7")
    }

    @Test func estimatedTokensIsAQuarterOfTheBytes() {
        #expect(ContextPack.estimatedTokens("") == 0)
        #expect(ContextPack.estimatedTokens("abcd") == 1)
        #expect(ContextPack.estimatedTokens(String(repeating: "a", count: 400)) == 100)
    }

    @Test func newSessionRules() {
        func start(_ last: TimeInterval?, consumed: Bool = false, has: Bool = true) -> Bool {
            SessionGrouping.shouldStartNewSession(
                now: base, lastActivity: last.map { base.addingTimeInterval(-$0) }, consumed: consumed, hasSession: has,
                idle: 300)
        }
        #expect(start(10) == false)
        #expect(start(301) == true)
        #expect(start(10, consumed: true) == true)
        #expect(start(10, has: false) == true)
        #expect(start(nil) == true)
    }
}
