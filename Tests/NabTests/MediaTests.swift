import Foundation
import Testing

@testable import NabCore

@Suite("Items made of photos and clips")
struct MediaTests {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func pin(_ media: [Media], title: String = "Paper lamp", author: String? = "maker") -> Capture {
        Capture(
            source: SourceKind(rawValue: "pinterest"), sourceID: "100200300",
            url: URL(string: "https://www.pinterest.com/pin/100200300/")!, title: title, author: author,
            summary: "Folded from one sheet.", media: media)
    }

    static let photo = Media(
        kind: .image, url: URL(string: "https://i.pinimg.com/originals/aa/bb/cc/abc.png")!, width: 1000, height: 1500)
    static let clip = Media(
        kind: .video, url: URL(string: "https://v1.pinimg.com/videos/mc/720p/aa/bb/cc/abc.mp4")!, width: 1080,
        height: 1920, duration: 42)

    /// A library file exactly as e50eb75 wrote it (synthetic values): it must still open, as a ready text item.
    @Test func filesFromBeforeMediaStillOpen() throws {
        let json = """
            {"addedAt":"2026-10-15T15:45:25Z","capture":{"author":"Some Channel","authorURL":"https://www.youtube.com/@some",\
            "chapters":[],"duration":212,"keywords":["demo"],"source":"youtube","sourceID":"aaaaaaaaaaa",\
            "summary":"About it.","thumbnailURL":"https://i.ytimg.com/vi/aaaaaaaaaaa/hqdefault.jpg","title":"A video",\
            "transcript":{"isGenerated":false,"languageCode":"en","languageName":"English",\
            "segments":[{"duration":2.5,"start":0,"text":"hello"}]},"url":"https://www.youtube.com/watch?v=aaaaaaaaaaa",\
            "viewCount":12},"id":"youtube:aaaaaaaaaaa","inTray":true,"sessionID":"s-1",\
            "url":"https://www.youtube.com/watch?v=aaaaaaaaaaa"}
            """
        let entry = try Self.decoder.decode(Entry.self, from: Data(json.utf8))
        #expect(entry.capture?.media == [])
        #expect(entry.capture?.isMedia == false)
        #expect(entry.phase == .ready)
        #expect(entry.capture?.transcript?.segments.count == 1)
    }

    /// The capture as e50eb75 declared it, with the synthesized decoder that version has.
    struct CaptureBeforeMedia: Codable {
        var source: SourceKind
        var sourceID: String
        var url: URL
        var title: String
        var author: String?
        var authorURL: URL?
        var duration: TimeInterval?
        var viewCount: Int?
        var summary: String?
        var keywords: [String]
        var thumbnailURL: URL?
        var chapters: [Chapter]
        var transcript: Transcript?
        var aiSummary: String?
        var aiModel: String?
    }

    /// A file this version writes still opens in the version before it: the new key is simply skipped.
    @Test func newFilesOpenInTheVersionBefore() throws {
        var capture = Self.pin([Self.photo, Self.clip])
        capture.media[0].savedPath = "/tmp/Paper lamp (Pinterest 100200300) 1.png"
        let data = try JSONEncoder().encode(capture)
        let old = try JSONDecoder().decode(CaptureBeforeMedia.self, from: data)
        #expect(old.title == "Paper lamp")
        #expect(old.sourceID == "100200300")
        #expect(try JSONDecoder().decode(Capture.self, from: data) == capture)
    }

    @Test func phaseComesFromWhatIsStored() {
        var entry = Entry(id: "pinterest:100200300", url: URL(string: "https://pin.it/x")!)
        #expect(entry.phase == .fetching)
        entry.capture = Self.pin([Self.photo, Self.clip])
        #expect(entry.phase == .saving)
        entry.failure = "Disk full"
        #expect(entry.phase == .failed)
        entry.failure = nil
        entry.capture?.media[0].savedPath = "/a.png"
        entry.capture?.media[1].savedPath = "/b.mp4"
        #expect(entry.phase == .ready)
        entry.capture = Self.pin([])
        #expect(entry.phase == .ready)
    }

    @Test func fileNamesAreReadableSafeAndShort() {
        #expect(
            MediaFileName.make(title: "Paper lamp", source: "Pinterest", id: "100200300", page: nil, ext: "png")
                == "Paper lamp (Pinterest 100200300).png")
        #expect(
            MediaFileName.make(title: "a/b: c\nd", source: "Pinterest", id: "1", page: 3, ext: "mp4")
                == "a-b- c d (Pinterest 1) 3.mp4")
        #expect(
            MediaFileName.make(title: "../../etc", source: "Pinterest", id: "1", page: nil, ext: "jpg")
                == "-..-etc (Pinterest 1).jpg")
        #expect(
            MediaFileName.make(title: "...", source: "Pinterest", id: "9", page: nil, ext: "jpg") == "(Pinterest 9).jpg"
        )
        let long = MediaFileName.make(
            title: String(repeating: "word ", count: 60), source: "Pinterest", id: "100200300", page: 12, ext: "jpeg")
        #expect(long.count <= MediaFileName.maxCharacters)
        #expect(long.hasSuffix(" (Pinterest 100200300) 12.jpeg"))
        let wide = MediaFileName.make(
            title: String(repeating: "🧵", count: 90), source: "Pinterest", id: "1", page: nil, ext: "png")
        #expect(wide.utf8.count <= MediaFileName.maxBytes)
        #expect(wide.hasSuffix(" (Pinterest 1).png"))
    }

    @Test func extensionsAreTheSourcesOrFitTheKind() {
        #expect(MediaFileName.ext(for: Self.photo) == "png")
        let odd = Media(kind: .video, url: URL(string: "https://example.com/stream?id=1")!)
        #expect(MediaFileName.ext(for: odd) == "mp4")
        let hostile = Media(kind: .image, url: URL(string: "https://example.com/x.p%2Fng")!)
        #expect(MediaFileName.ext(for: hostile) == "jpg")
        #expect(
            MediaFileName.names(for: Self.pin([Self.photo, Self.clip]), sourceName: "Pinterest") == [
                "Paper lamp (Pinterest 100200300) 1.png", "Paper lamp (Pinterest 100200300) 2.mp4",
            ])
    }

    @Test func mediaFolderPrefersTheUsersChoiceThenTheDataFolder() {
        let downloads = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)
        #expect(
            MediaFolder.resolve(setting: "/Volumes/Art", environment: [:], downloads: downloads).path == "/Volumes/Art")
        #expect(
            MediaFolder.resolve(
                setting: "relative/path", environment: ["NAB_DATA_DIR": "/tmp/demo"], downloads: downloads
            )
            .path == "/tmp/demo/Media")
        #expect(
            MediaFolder.resolve(setting: nil, environment: [:], downloads: downloads).path == downloads.path + "/Nab")
        #expect(
            MediaFolder.resolve(setting: "", environment: ["NAB_DATA_DIR": ""], downloads: downloads).path
                == downloads.path + "/Nab")
    }

    /// Videos read as text pack exactly as they did before photos and clips existed.
    @Test func videoPacksAreByteForByteUnchanged() {
        #expect(ContextPack.render(PackGolden.captures, capturedAt: PackGolden.day) == PackGolden.pack)
    }

    @Test func packListsPhotosAndClipsWithTheirFiles() {
        var capture = Self.pin([Self.photo, Self.clip])
        capture.media[0].savedPath = "/Volumes/Archive/Nab/Paper lamp (Pinterest 100200300) 1.png"
        let pack = ContextPack.source(capture)
        #expect(pack.contains("- By: maker\n- Media: 1 video and 1 photo\n"))
        #expect(pack.contains("## Media\n- Photo · 1000×1500 · Paper lamp (Pinterest 100200300) 1.png\n"))
        #expect(!pack.contains("/Volumes/Archive"))
        #expect(pack.contains("- Video · 1080×1920 · 0:42 · https://v1.pinimg.com/videos/mc/720p/aa/bb/cc/abc.mp4\n"))
        #expect(pack.contains("## Description\nFolded from one sheet."))
        #expect(!pack.contains("Transcript:"))
    }

    @Test func talliesCountEveryKind() {
        #expect(RackText.count(Tally(videos: 2, photos: 3)) == "2 videos and 3 photos")
        #expect(RackText.count(Tally(photos: 4)) == "4 photos")
        #expect(RackText.count(Tally(videos: 1)) == "1 video")
        #expect(RackText.count(Tally()) == "0 items")
        #expect(RackText.count(Tally(videos: 1, photos: 2, items: 1)) == "1 video, 2 photos and 1 item")
        #expect(RackText.copied(Tally(photos: 4)) == "Copied 4 photos")
        var video = Entry(id: "youtube:a", url: URL(string: "https://youtu.be/a")!)
        video.capture = Capture(
            source: .youtube, sourceID: "a", url: video.url, title: "A",
            transcript: Transcript(
                languageCode: "en", languageName: nil, isGenerated: false,
                segments: [Segment(start: 0, duration: 1, text: "hi")]))
        var pin = Entry(id: "pinterest:1", url: URL(string: "https://pin.it/a")!)
        pin.capture = Self.pin([Self.photo, Self.photo, Self.clip])
        let fetching = Entry(id: "pinterest:2", url: URL(string: "https://pin.it/b")!)
        #expect(Tally([video, pin, fetching]) == Tally(videos: 2, photos: 2, items: 1))
        #expect(RackText.supportedSources(["YouTube", "Pinterest"]) == "Nab reads YouTube and Pinterest links.")
        #expect(RackText.supportedSources(["YouTube"]) == "Nab reads YouTube links.")
    }

    @Test func kindLinesDescribeWhatTheItemIs() {
        #expect(RackText.kindLine(Self.pin([Self.photo])) == "Photo · 1000×1500")
        #expect(RackText.kindLine(Self.pin([Self.clip])) == "Video · 0:42")
        #expect(RackText.kindLine(Self.pin(Array(repeating: Self.photo, count: 4))) == "4 photos")
        #expect(RackText.kindLine(Self.pin([Self.photo]), saving: 0.426) == "Saving… 42%")
        #expect(RackText.kindLine(Capture(source: .youtube, sourceID: "a", url: Self.photo.url, title: "A")) == nil)
    }

    @Test func copyHandsOverFilesForPhotosAndThePackForText() {
        let day = Date(timeIntervalSince1970: 0)
        var saved = Self.pin([Self.photo, Self.clip])
        saved.media[0].savedPath = "/m/1.png"
        saved.media[1].savedPath = "/m/2.mp4"
        let unsaved = Self.pin([Self.photo])
        var half = saved
        half.media[1].savedPath = nil
        let video = Capture(source: .youtube, sourceID: "a", url: URL(string: "https://youtu.be/a")!, title: "A")
        #expect(CopyPayload.single(saved) == .files([URL(filePath: "/m/1.png"), URL(filePath: "/m/2.mp4")]))
        #expect(CopyPayload.single(unsaved, capturedAt: day) == .text(ContextPack.render([unsaved], capturedAt: day)))
        #expect(CopyPayload.single(half, capturedAt: day) == .text(ContextPack.render([half], capturedAt: day)))
        #expect(CopyPayload.single(video, capturedAt: day) == .text(ContextPack.render([video], capturedAt: day)))
        #expect(
            CopyPayload.session([saved, video], capturedAt: day)
                == .text(ContextPack.render([saved, video], capturedAt: day)))
        #expect(CopyPayload.session([saved, saved]).files?.count == 4)
        #expect(CopyPayload.missing([saved]) { $0 == "/m/1.png" ? 1 : nil } == [saved.media[1]])
    }

    struct ShortLinks: SourceProvider {
        let kind = SourceKind(rawValue: "pins")
        let name = "Pins"
        func identify(_ url: URL) -> String? {
            url.host() == "pins.example" ? url.lastPathComponent : nil
        }
        func isShortLink(_ url: URL) -> Bool { url.host() == "p.example" }
        func expand(_ url: URL) async throws -> URL {
            URL(string: "https://pins.example/pin/\(url.lastPathComponent)")!
        }
        func fetch(_ url: URL) async throws -> Capture { throw NabError("unused") }
    }

    @Test func registryReadsShortLinksAndNamesItsSources() async throws {
        let registry = SourceRegistry([ShortLinks()])
        let text =
            "https://p.example/abc and again https://p.example/abc, https://pins.example/pin/7 and https://x.example"
        #expect(
            registry.links(in: text).map(\.absoluteString) == ["https://p.example/abc", "https://pins.example/pin/7"])
        #expect(registry.supports(URL(string: "https://p.example/abc")!))
        #expect(!registry.supports(URL(string: "https://x.example/abc")!))
        #expect(
            try await registry.expand(URL(string: "https://p.example/abc")!).absoluteString
                == "https://pins.example/pin/abc")
        #expect(
            try await registry.expand(URL(string: "https://x.example/abc")!).absoluteString == "https://x.example/abc")
        #expect(registry.names == ["Pins"])
        #expect(registry.name(for: SourceKind(rawValue: "gone")) == "Gone")
    }
}

extension CopyPayload {
    fileprivate var files: [URL]? {
        if case .files(let files) = self { return files }
        return nil
    }
}
