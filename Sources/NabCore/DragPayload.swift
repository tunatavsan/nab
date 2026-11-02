import Foundation

/// What a drag of one item carries: the same thing its Copy hands over, unless a saved file has gone missing.
public enum DragPayload {
    /// Nil when the drag must not start: a saved file is no longer where Nab put it, so the next app would get
    /// nothing (the item shows "File moved or deleted" instead).
    public static func resolve(
        _ capture: Capture, capturedAt: Date = .now,
        size: (String) -> Int64? = { MediaProbe.fileSize(atPath: $0) }
    ) -> CopyPayload? {
        guard CopyPayload.missing([capture], size: size).isEmpty else { return nil }
        return CopyPayload.single(capture, capturedAt: capturedAt)
    }
}
