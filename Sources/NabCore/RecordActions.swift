import Foundation

/// What a record page offers, decided from what the record is made of rather than where it came from.
public enum RecordActions {
    /// "Open on YouTube", "Open on Pinterest".
    public static func openLabel(sourceName: String) -> String { "Open on \(sourceName)" }

    /// The saved files "Show in Finder" selects: only those Copy would hand over (on disk at the size they were saved
    /// at); empty for a record read as text. `size` is a file's size, nil when there is none.
    public static func finderFiles(
        _ capture: Capture, size: (String) -> Int64? = { MediaProbe.fileSize(atPath: $0) }
    ) -> [URL] {
        let missing = CopyPayload.missing([capture], size: size)
        return capture.media.compactMap { item in
            guard let path = item.savedPath, !missing.contains(item) else { return nil }
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
