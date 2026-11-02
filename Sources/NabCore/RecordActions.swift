import Foundation

/// What a record page offers, decided from what the record is made of rather than where it came from.
public enum RecordActions {
    /// "Open on YouTube", "Open on Pinterest".
    public static func openLabel(sourceName: String) -> String { "Open on \(sourceName)" }

    /// The saved files "Show in Finder" selects: only those still on disk; empty for a record read as text.
    public static func finderFiles(
        _ capture: Capture, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        capture.media.compactMap { item in
            guard let path = item.savedPath, exists(path) else { return nil }
            return URL(filePath: path)
        }
    }

    /// Whether the player embedded in the app is the one for this record. A record that is not a YouTube video has no
    /// video id, and no player running has none either: two absences are not a match.
    public static func isEmbedded(playing: String?, entryID: String) -> Bool {
        guard let playing, let own = YouTubeID.id(fromEntryID: entryID) else { return false }
        return playing == own
    }
}
