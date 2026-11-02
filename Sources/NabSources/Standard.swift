import NabCore
import NabYouTube

extension SourceRegistry {
    /// Every source Nab reads, in the order a link is tried. A new source is a new target and one line here; the
    /// app, the CLI, the library and the context pack pick it up from this list.
    public static let standard = SourceRegistry([
        YouTubeSource()
    ])
}
