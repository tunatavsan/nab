import Foundation
import NabCore
import NabYouTube

extension SourceRegistry {
    /// The sources the app reads. Everything source-specific the interface shows comes through here.
    static let standard = SourceRegistry([YouTubeSource()])
}

extension Entry {
    /// Cover images, largest first.
    var coverURLs: [URL] { SourceRegistry.standard.covers(for: self) }

    /// The smallest of the source's own covers, for list rows and toasts.
    var thumbnailURL: URL? {
        SourceRegistry.standard.provider(for: source)?.covers(forID: sourceID).last ?? capture?.thumbnailURL
    }
}

extension Capture {
    /// A link that opens the source at a moment, or the source itself when it has no such links.
    func url(at seconds: TimeInterval) -> URL { SourceRegistry.standard.link(to: self, at: seconds) }
}

extension SourceKind {
    /// How the interface names a source; `rawValue` is the stable id used in files.
    var displayName: String {
        self == .youtube ? "YouTube" : rawValue.capitalized
    }
}
