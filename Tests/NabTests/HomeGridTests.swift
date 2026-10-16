import Testing

@testable import NabCore

@Suite("Home grid")
struct HomeGridTests {
    private func run(_ session: Int, _ row: Int, _ column: Int, _ length: Int, continues: Bool = false)
        -> HomeGrid.Run
    {
        HomeGrid.Run(session: session, row: row, column: column, length: length, continues: continues)
    }

    @Test("a session that fits is one run in the first row")
    func singleRow() {
        #expect(HomeGrid.runs(itemCounts: [3], columns: 5) == [run(0, 0, 0, 3)])
    }

    @Test("a session wraps onto the next row and the second run continues it")
    func wraps() {
        #expect(
            HomeGrid.runs(itemCounts: [7], columns: 5) == [run(0, 0, 0, 5), run(0, 1, 0, 2, continues: true)])
        #expect(
            HomeGrid.runs(itemCounts: [12], columns: 5)
                == [run(0, 0, 0, 5), run(0, 1, 0, 5, continues: true), run(0, 2, 0, 2, continues: true)])
    }

    @Test("small sessions pack into one row")
    func packs() {
        #expect(
            HomeGrid.runs(itemCounts: [1, 2, 2], columns: 5) == [run(0, 0, 0, 1), run(1, 0, 1, 2), run(2, 0, 3, 2)])
    }

    @Test("the next session starts in the free cell and may wrap")
    func startsMidRow() {
        #expect(
            HomeGrid.runs(itemCounts: [3, 4], columns: 5)
                == [run(0, 0, 0, 3), run(1, 0, 3, 2), run(1, 1, 0, 2, continues: true)])
    }

    @Test("a session that fills a row exactly is followed by the next one on a new row")
    func exactRow() {
        #expect(HomeGrid.runs(itemCounts: [5, 2], columns: 5) == [run(0, 0, 0, 5), run(1, 1, 0, 2)])
    }

    @Test("sessions without items take no cell")
    func skipsEmpty() {
        #expect(HomeGrid.runs(itemCounts: [0, 2, 0, 1], columns: 5) == [run(1, 0, 0, 2), run(3, 0, 2, 1)])
        #expect(HomeGrid.runs(itemCounts: [], columns: 5).isEmpty)
        #expect(HomeGrid.runs(itemCounts: [0, 0], columns: 5).isEmpty)
    }

    @Test("one column puts every item on its own row")
    func oneColumn() {
        #expect(
            HomeGrid.runs(itemCounts: [2, 1], columns: 1)
                == [run(0, 0, 0, 1), run(0, 1, 0, 1, continues: true), run(1, 2, 0, 1)])
    }

    @Test("a non-positive column count places nothing")
    func noColumns() {
        #expect(HomeGrid.runs(itemCounts: [2], columns: 0).isEmpty)
    }
}
