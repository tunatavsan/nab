import Foundation

/// What "Copy" (and a drag) hands to the next app: the thing that app should receive. Photos and clips go as their
/// files; an item read as text goes as its context pack.
public enum CopyPayload: Equatable, Sendable {
    case text(String)
    case files([URL])

    /// One item: its saved files when it is made of photos and clips and all of them are saved, else its pack.
    public static func single(_ capture: Capture, capturedAt: Date = .now) -> CopyPayload {
        if capture.isMedia, let files = savedFiles([capture]) { return .files(files) }
        return .text(ContextPack.render([capture], capturedAt: capturedAt))
    }

    /// A session: the pack when any item in it is read as text (photos and clips are listed in the pack with their
    /// files), else every saved file. Files that are not all saved yet fall back to the pack, which names them.
    public static func session(_ captures: [Capture], capturedAt: Date = .now) -> CopyPayload {
        if !captures.isEmpty, captures.allSatisfy(\.isMedia), let files = savedFiles(captures) { return .files(files) }
        return .text(ContextPack.render(captures, capturedAt: capturedAt))
    }

    /// Saved files that are no longer where Nab put them; checked when they are used, never while drawing.
    public static func missing(
        _ captures: [Capture], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Media] {
        captures.flatMap(\.media).filter { $0.savedPath.map { !exists($0) } ?? false }
    }

    private static func savedFiles(_ captures: [Capture]) -> [URL]? {
        let media = captures.flatMap(\.media)
        let files = media.compactMap(\.savedURL)
        return files.count == media.count && !files.isEmpty ? files : nil
    }
}
