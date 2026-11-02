import Foundation
import UniformTypeIdentifiers

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

    /// The photo in a copy of exactly one photo: it also goes as picture data, so an image editor or a chat gets the
    /// picture while Finder gets the file. Nil for text, a clip, or several files.
    public var loneImage: URL? {
        guard case .files(let files) = self, files.count == 1, let file = files.first,
            let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image)
        else { return nil }
        return file
    }

    /// Saved files that are no longer where Nab put them: gone, or left empty. A file the user edited since stays
    /// theirs and is used as it is. Checked when they are used, never while drawing. `size` is a file's size, nil
    /// when there is none.
    public static func missing(
        _ captures: [Capture], size: (String) -> Int64? = { MediaProbe.fileSize(atPath: $0) }
    ) -> [Media] {
        captures.flatMap(\.media).filter { item in item.savedPath.map { !Media.isPresent(size: size($0)) } ?? false }
    }

    private static func savedFiles(_ captures: [Capture]) -> [URL]? {
        let media = captures.flatMap(\.media)
        let files = media.compactMap(\.savedURL)
        return files.count == media.count && !files.isEmpty ? files : nil
    }
}
