import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads what a saved file really is. A source's own numbers can be wrong (Pinterest lists 1080×1920 for clips
/// that are 540×960), and a fallback copy can be a JPEG where the original was a PNG.
public enum MediaProbe {
    public struct Facts: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var duration: TimeInterval?
        /// The file's real type, for images.
        public var type: UTType?
    }

    public static func facts(of file: URL, kind: Media.Kind) async -> Facts? {
        kind == .video ? await video(file) : image(file)
    }

    static func image(_ file: URL) -> Facts? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        return Facts(width: width, height: height, duration: nil, type: type)
    }

    static func video(_ file: URL) async -> Facts? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        return Facts(
            width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()),
            duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, type: nil)
    }

    /// A file already saved under `file`'s name: that name, or the same name with the extension a misnamed copy was
    /// renamed to. Empty files do not count.
    public static func existing(_ file: URL, fileManager: FileManager = .default) -> URL? {
        if size(of: file, fileManager: fileManager) > 0 { return file }
        let stem = file.deletingPathExtension().lastPathComponent
        let folder = file.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.lazy
            .filter { $0 != file.lastPathComponent && !$0.hasSuffix(".partial") }
            .map { folder.appending(path: $0) }
            .first { candidate in
                candidate.deletingPathExtension().lastPathComponent == stem
                    && size(of: candidate, fileManager: fileManager) > 0
            }
    }

    static func size(of file: URL, fileManager: FileManager = .default) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The name a file should have when its contents are another type than its extension says (`x.png` holding a
    /// JPEG), or nil when the name already fits.
    public static func corrected(_ file: URL, type: UTType?) -> URL? {
        guard let type, let ext = type.preferredFilenameExtension else { return nil }
        if let current = UTType(filenameExtension: file.pathExtension), current.conforms(to: type) { return nil }
        return file.deletingPathExtension().appendingPathExtension(ext)
    }
}

extension SourceProvider {
    /// Saves one photo or clip of `capture` through this source and returns it as it now is on disk: its path, its
    /// size, and the size, length and type read from the file itself (a misnamed fallback copy is renamed to its real
    /// type). A file already in the folder under this item's name is kept and not downloaded again: the name carries
    /// the source's id, so it can only be this item, saved before.
    public func store(
        _ media: Media, of capture: Capture, at file: URL,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void = { _, _ in }
    ) async throws -> Media {
        var file = file
        var facts: MediaProbe.Facts?
        if let earlier = MediaProbe.existing(file) {
            file = earlier
            facts = await MediaProbe.facts(of: file, kind: media.kind)
        } else {
            try await save(media, of: capture, to: file, progress: progress)
            facts = await MediaProbe.facts(of: file, kind: media.kind)
            if let better = MediaProbe.corrected(file, type: facts?.type),
                (try? FileManager.default.moveItem(at: file, to: better)) != nil
            {
                file = better
            }
        }
        var item = media
        item.savedPath = file.path
        item.byteCount = MediaProbe.size(of: file)
        if let facts {
            item.width = facts.width
            item.height = facts.height
            item.duration = facts.duration ?? item.duration
        }
        return item
    }
}
