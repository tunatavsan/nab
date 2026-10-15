import Foundation
import NabCore

/// Reads YouTube videos through the InnerTube player endpoint with the Android client, which returns
/// caption tracks that do not need a proof-of-origin token. Two requests per video, no API key and no
/// watch-page download (verified 2026-10-11: player ≈ 0.4 s, captions ≈ 0.2 s).
public struct YouTubeSource: SourceProvider {
    public let kind = SourceKind.youtube
    private let session: URLSession
    /// The Android client version YouTube currently accepts. When YouTube retires it, only this
    /// value (and the user agent) changes.
    static let clientVersion = "20.10.38"
    static let userAgent = "com.google.android.youtube/\(clientVersion) (Linux; U; Android 14) gzip"

    public init(session: URLSession = .nab) {
        self.session = session
    }

    public func covers(forID id: String) -> [URL] {
        ["maxresdefault", "hqdefault", "mqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg") }
    }

    public func link(to capture: Capture, at seconds: TimeInterval) -> URL {
        var parts = URLComponents(string: "https://www.youtube.com/watch")
        parts?.queryItems = [
            .init(name: "v", value: capture.sourceID), .init(name: "t", value: "\(seconds.wholeSeconds)s"),
        ]
        return parts?.url ?? capture.url
    }

    public func identify(_ url: URL) -> String? { YouTubeURL.videoID(in: url) }

    public func fetch(_ url: URL) async throws -> Capture {
        guard let id = YouTubeURL.videoID(in: url) else { throw NabError("Not a YouTube video link.") }
        let player = try await player(id)

        if let status = player.playabilityStatus, status.status != "OK" {
            throw NabError(status.reason ?? "YouTube will not play this video (\(status.status)).")
        }
        guard let details = player.videoDetails else { throw NabError("YouTube returned no details for this video.") }

        let description = details.shortDescription ?? ""
        var capture = Capture(
            source: .youtube,
            sourceID: id,
            url: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            title: details.title,
            author: details.author,
            authorURL: details.channelId.flatMap { URL(string: "https://www.youtube.com/channel/\($0)") },
            duration: details.lengthSeconds.flatMap(TimeInterval.init),
            viewCount: details.viewCount.flatMap(Int.init),
            summary: description.isEmpty ? nil : description,
            keywords: details.keywords ?? [],
            thumbnailURL: details.thumbnail?.thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }.flatMap {
                URL(string: $0.url)
            },
            chapters: YouTubeChapters.parse(description)
        )

        if let track = Self.preferredTrack(in: player) {
            capture.transcript = try await transcript(track)
        }
        return capture
    }

    /// The track in the video's original audio language: a human track beats the auto-generated one, then
    /// the track YouTube marks as the original's default, then `preferredTrack(_:)`. Auto-dubbed videos
    /// list one auto-generated track per dub language, so the first of them is rarely the original.
    /// An audio track id ending in ".4" is the original (".3" and ".10" are dubs); the default audio track
    /// follows the viewer's language and can be a dub, so it only counts when no track is marked.
    static func preferredTrack(in player: Player) -> Player.Track? {
        let list = player.captions?.playerCaptionsTracklistRenderer
        let tracks = list?.captionTracks ?? []
        let audio = list?.audioTracks ?? []
        let defaultAudio = list?.defaultAudioTrackIndex.flatMap { audio.indices.contains($0) ? audio[$0] : nil }
        let isOriginal: (Player.Captions.AudioTrack) -> Bool = { $0.audioTrackId?.hasSuffix(".4") == true }
        let originalAudio = defaultAudio.flatMap { isOriginal($0) ? $0 : nil } ?? audio.first(where: isOriginal)
        let original =
            (originalAudio ?? defaultAudio)?.audioTrackId
            ?? player.streamingData?.adaptiveFormats?.first { $0.audioTrack?.audioIsDefault == true }?.audioTrack?.id
        if let language = original.flatMap(Self.language(ofAudioTrack:)) {
            func speaks(_ track: Player.Track) -> Bool {
                Locale.Language(identifier: track.languageCode).languageCode?.identifier == language
            }
            if let match = tracks.first(where: { $0.kind != "asr" && speaks($0) })
                ?? tracks.first(where: { $0.kind == "asr" && speaks($0) })
            {
                return match
            }
        }
        if let index = (originalAudio ?? defaultAudio)?.defaultCaptionTrackIndex, tracks.indices.contains(index) {
            return tracks[index]
        }
        return preferredTrack(tracks)
    }

    /// The language code of an audio track id such as "en-US.4" ("en"); the suffix is the audio kind.
    private static func language(ofAudioTrack id: String) -> String? {
        let tag = id.split(separator: ".").first.map(String.init) ?? id
        return Locale.Language(identifier: tag).languageCode?.identifier
    }

    /// Without any original-language hint: the spoken language is the language of the first
    /// auto-generated track; a human track in that language beats it, and any human track beats nothing.
    static func preferredTrack(_ tracks: [Player.Track]) -> Player.Track? {
        let asr = tracks.first { $0.kind == "asr" }
        let human = tracks.filter { $0.kind != "asr" }
        if let spoken = asr.flatMap({ Locale.Language(identifier: $0.languageCode).languageCode }),
            let match = human.first(where: { Locale.Language(identifier: $0.languageCode).languageCode == spoken })
        {
            return match
        }
        return asr ?? human.first
    }

    private func player(_ id: String) async throws -> Player {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "ANDROID", "clientVersion": Self.clientVersion, "hl": "en"]],
            "videoId": id,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await hedged(request)
        try Self.check(response, "video details")
        return try JSONDecoder().decode(Player.self, from: data)
    }

    private func transcript(_ track: Player.Track) async throws -> Transcript {
        guard var parts = URLComponents(string: track.baseUrl) else { throw NabError("Caption link is malformed.") }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "fmt" } + [.init(name: "fmt", value: "json3")]
        guard let url = parts.url else { throw NabError("Caption link is malformed.") }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await hedged(request)
        try Self.check(response, "captions")
        return Transcript(
            languageCode: track.languageCode,
            languageName: track.name?.text.replacingOccurrences(of: " (auto-generated)", with: ""),
            isGenerated: track.kind == "asr",
            segments: try TimedText.segments(from: data)
        )
    }

    /// Both requests usually answer in 0.2–0.4 s, but now and then one stalls for ~10 s (measured
    /// 2026-10-11, in the CLI and the app alike). If no answer has come after `delay`, the same request
    /// goes out again on a fresh connection and whichever answers first wins. The 450 ms default sits
    /// above the normal answer time and below the stalls (2026-10-15: timedtext p50 0.24 s, and 4 of 20
    /// cold requests stalled 1.3–10.3 s; player max 0.37 s), so a healthy request is rarely doubled.
    private func hedged(_ request: URLRequest, delay: Duration = .milliseconds(450)) async throws -> (
        Data, URLResponse
    ) {
        let session = session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: delay)
                return try await URLSession.nabHedge.data(for: request)
            }
            defer { group.cancelAll() }
            var lastError: Error = NabError("YouTube did not answer.")
            for _ in 0..<2 {
                do {
                    if let result = try await group.next() { return result }
                } catch is CancellationError {
                    continue
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func check(_ response: URLResponse, _ what: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 429 { throw NabError("YouTube is rate limiting requests. Try again in a minute.") }
        guard (200..<300).contains(http.statusCode) else {
            throw NabError("YouTube refused the \(what) request (HTTP \(http.statusCode)).")
        }
    }
}

extension URLSession {
    /// One shared session: keeps connections to youtube.com warm across a batch.
    public static let nab: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept-Language": "en"]
        return URLSession(configuration: config)
    }()

    /// A second pool, so a hedged retry never waits behind the connection that stalled.
    static let nabHedge: URLSession = URLSession(configuration: nab.configuration)
}

public enum YouTubeURL {
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    ]

    /// Video id from watch, shorts, live, embed and youtu.be links.
    public static func videoID(in url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        var candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if hosts.contains(host) {
            if path.first == "watch" {
                candidate =
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) {
                candidate = path[1]
            }
        }
        guard let id = candidate, id.count == 11,
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }
}

public enum YouTubeChapters {
    /// Chapters as YouTube derives them: timestamped lines in the description, the first at 0:00.
    public static func parse(_ description: String) -> [Chapter] {
        let pattern = /^\s*[\(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?\s*[-–—:|·]?\s*(.+?)\s*$/
        var chapters: [Chapter] = []
        for line in description.split(whereSeparator: \.isNewline) {
            guard let match = try? pattern.firstMatch(in: String(line)) else { continue }
            let seconds = match.1.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
            let title = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: "-–—:| "))
            guard !title.isEmpty else { continue }
            if let last = chapters.last, TimeInterval(seconds) <= last.start { continue }
            chapters.append(Chapter(start: TimeInterval(seconds), title: title))
        }
        guard chapters.first?.start == 0, chapters.count >= 2 else { return [] }
        return chapters
    }
}

enum TimedText {
    struct Body: Decodable {
        struct Event: Decodable {
            let tStartMs: Int?
            let dDurationMs: Int?
            let segs: [Seg]?
        }
        struct Seg: Decodable { let utf8: String? }
        let events: [Event]?
    }

    static func segments(from data: Data) throws -> [Segment] {
        let body = try JSONDecoder().decode(Body.self, from: data)
        return (body.events ?? []).compactMap { event in
            guard let start = event.tStartMs, let segs = event.segs else { return nil }
            let text = segs.compactMap(\.utf8).joined()
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { return nil }
            return Segment(start: Double(start) / 1000, duration: Double(event.dDurationMs ?? 0) / 1000, text: text)
        }
    }
}

struct Player: Decodable {
    struct Status: Decodable {
        let status: String
        let reason: String?
    }
    struct Details: Decodable {
        struct Thumbnails: Decodable {
            struct Thumb: Decodable {
                let url: String
                let width: Int?
            }
            let thumbnails: [Thumb]
        }
        let title: String
        let lengthSeconds: String?
        let channelId: String?
        let shortDescription: String?
        let author: String?
        let viewCount: String?
        let keywords: [String]?
        let thumbnail: Thumbnails?
    }
    struct Track: Decodable {
        struct Name: Decodable {
            struct Run: Decodable { let text: String }
            let simpleText: String?
            let runs: [Run]?
            var text: String { simpleText ?? runs?.map(\.text).joined() ?? "" }
        }
        let baseUrl: String
        let languageCode: String
        let kind: String?
        let name: Name?
    }
    struct Captions: Decodable {
        struct AudioTrack: Decodable {
            let audioTrackId: String?
            let defaultCaptionTrackIndex: Int?
        }
        struct Tracklist: Decodable {
            let captionTracks: [Track]?
            let audioTracks: [AudioTrack]?
            let defaultAudioTrackIndex: Int?
        }
        let playerCaptionsTracklistRenderer: Tracklist?
    }
    struct StreamingData: Decodable {
        struct Format: Decodable {
            struct Audio: Decodable {
                let id: String?
                let audioIsDefault: Bool?
            }
            let audioTrack: Audio?
        }
        let adaptiveFormats: [Format]?
    }
    let playabilityStatus: Status?
    let streamingData: StreamingData?
    let videoDetails: Details?
    let captions: Captions?
}
