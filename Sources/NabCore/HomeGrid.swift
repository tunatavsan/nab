import Foundation

/// Placement of sessions on the home page's column grid.
public enum HomeGrid {
    /// The cells one session occupies in one grid row.
    public struct Run: Equatable, Sendable {
        /// Index into the `itemCounts` given.
        public let session: Int
        public let row: Int
        public let column: Int
        public let length: Int
        /// True when the session already had cells in the row above.
        public let continues: Bool

        public init(session: Int, row: Int, column: Int, length: Int, continues: Bool) {
            self.session = session
            self.row = row
            self.column = column
            self.length = length
            self.continues = continues
        }
    }

    /// The runs of sessions laid out back to back, `itemCounts[i]` cells each, on a grid `columns` wide.
    /// A session with no cells has no run; a session that wraps has one run per row it touches.
    public static func runs(itemCounts: [Int], columns: Int) -> [Run] {
        guard columns > 0 else { return [] }
        var result: [Run] = []
        var cell = 0
        for (session, count) in itemCounts.enumerated() where count > 0 {
            var left = count
            var continues = false
            while left > 0 {
                let column = cell % columns
                let length = min(left, columns - column)
                result.append(
                    Run(
                        session: session, row: cell / columns, column: column, length: length,
                        continues: continues))
                cell += length
                left -= length
                continues = true
            }
        }
        return result
    }
}
