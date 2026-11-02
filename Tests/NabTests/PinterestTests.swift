import Foundation
import NabCore
import Testing

@testable import NabPinterest

/// Answers every request of a test session from a closure, so the tests never touch the network. Each session carries
/// its own router (found by a header), so tests running side by side do not see each other's requests.
final class PinterestStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    final class Router: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private let handler: @Sendable (URLRequest) -> Reply?
        init(_ handler: @escaping @Sendable (URLRequest) -> Reply?) { self.handler = handler }
        func answer(_ request: URLRequest) -> Reply {
            lock.withLock { seen.append("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")") }
            return handler(request) ?? Reply(status: 418)
        }
        var requests: [String] { lock.withLock { seen } }
        func count(_ method: String) -> Int { requests.filter { $0.hasPrefix(method + " ") }.count }
    }

    nonisolated(unsafe) private static var routers: [String: Router] = [:]
    private static let lock = NSLock()

    static func session(_ handler: @escaping @Sendable (URLRequest) -> Reply?) -> (URLSession, Router) {
        let token = UUID().uuidString
        let router = Router(handler)
        lock.withLock { routers[token] = router }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinterestStub.self]
        config.httpAdditionalHeaders = ["X-Stub-Router": token]
        return (URLSession(configuration: config), router)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Stub-Router") ?? ""
        let router = Self.lock.withLock { Self.routers[token] }
        let reply = router?.answer(request) ?? Reply(status: 500)
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(reply.body.count)" }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Pins as the API shapes them, with invented ids, names and hashes.
private enum Fake {
    static func hash(_ n: Int) -> String { "c0ffee" + String(format: "%026x", n) }

    static func image(_ size: String, _ n: Int, _ ext: String = "jpg") -> String {
        let h = hash(n)
        return
            "https://i.pinimg.com/\(size)/\(h.prefix(2))/\(h.dropFirst(2).prefix(2))/\(h.dropFirst(4).prefix(2))/\(h).\(ext)"
    }

    static func clip(_ folder: String, _ n: Int, suffix: String = "", ext: String = "mp4") -> String {
        let h = hash(n)
        return
            "https://v1.pinimg.com/videos/mc/\(folder)/\(h.prefix(2))/\(h.dropFirst(2).prefix(2))/\(h.dropFirst(4).prefix(2))/\(h)\(suffix).\(ext)"
    }

    static func entry(_ url: String, ms: Int = 5000, w: Int = 1080, h: Int = 1920) -> [String: Any] {
        ["url": url, "width": w, "height": h, "duration": ms, "thumbnail": image("originals", 900)]
    }

    /// The renditions an idea pin lists, in no useful order.
    static func ideaClip(_ n: Int, ms: Int = 4000) -> [String: Any] {
        [
            "video_list": [
                "V_EXP6": entry(clip("expMp4", n, suffix: "_t4"), ms: ms),
                "V_EXP7": entry(clip("720p", n), ms: ms),
                "V_EXP3": entry(clip("expMp4", n, suffix: "_t1"), ms: ms),
                "V_HLSV3_MOBILE": entry(clip("hls", n, ext: "m3u8"), ms: ms),
            ]
        ]
    }

    static func api(_ data: [String: Any]?) -> PinterestStub.Reply {
        let body: [String: Any] = ["resource_response": ["status": "success", "data": data as Any]]
        return PinterestStub.Reply(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
    }

    static func html(_ text: String) -> PinterestStub.Reply {
        PinterestStub.Reply(status: 200, body: Data(text.utf8))
    }

    static func isAPI(_ request: URLRequest) -> Bool { request.url?.path() == "/resource/PinResource/get/" }

    static func source(_ handler: @escaping @Sendable (URLRequest) -> PinterestStub.Reply?) -> (
        PinterestSource, PinterestStub.Router
    ) {
        let (session, router) = PinterestStub.session(handler)
        let downloader = MediaDownloader(session: session, attempts: 1, backoff: .milliseconds(1))
        return (PinterestSource(session: session, downloader: downloader, backoff: .milliseconds(1)), router)
    }

    static let pin = URL(string: "https://www.pinterest.com/pin/111222333/")!
}

@Suite("Pinterest")
struct PinterestTests {
    // MARK: Links

    @Test func recognisesEveryShapeOfPinLink() {
        let source = PinterestSource()
        for link in [
            "https://www.pinterest.com/pin/352688214593322121/",
            "https://pinterest.com/pin/352688214593322121",
            "https://tr.pinterest.com/pin/some-title-here--352688214593322121/",
            "https://www.pinterest.co.uk/pin/352688214593322121/",
            "https://uk.pinterest.com/pin/352688214593322121/",
            "https://www.pinterest.com/pin/352688214593322121/sent/?invite_code=abc123&sfo=1",
            "http://www.pinterest.fr/pin/352688214593322121/?utm_source=x",
        ] {
            #expect(source.identify(URL(string: link)!) == "352688214593322121", "\(link)")
        }
    }

    @Test func tellsShortAndDirectLinksApartAndRefusesTheRest() {
        let source = PinterestSource()
        let short = URL(string: "https://pin.it/7cg7eAE")!
        #expect(source.isShortLink(short))
        #expect(source.identify(short) == nil)
        #expect(!source.isShortLink(URL(string: "https://pin.it/")!))

        let direct = URL(string: Fake.image("736x", 1))!
        #expect(source.identify(direct) == Fake.hash(1))
        #expect(!source.isShortLink(direct))

        for link in [
            "https://www.pinterest.com/pin/create/button/", "https://www.pinterest.com/someone/boards/",
            "https://notpinterest.com/pin/352688214593322121/", "https://pinterest.co.uk.ab/pin/352688214593322121/",
            "https://pinterest.com.evil.test/pin/352688214593322121/",
            "https://www.pinterest.com/pin/abc--/", "https://i.pinimg.com/736x/not/a/hash.jpg",
            "https://example.com/pin/352688214593322121/", "https://www.youtube.com/watch?v=8jPQjjsBbIc",
        ] {
            #expect(source.identify(URL(string: link)!) == nil, "\(link)")
        }
    }

    @Test func shortLinksAreReadNotFollowed() async throws {
        let (source, router) = Fake.source { request in
            guard request.url?.path() == "/url_shortener/abc123/redirect/" else { return nil }
            return .init(
                status: 302,
                headers: ["Location": "https://www.pinterest.com/pin/111222333/sent/?invite_code=zz"])
        }
        let expanded = try await source.expand(URL(string: "https://pin.it/abc123")!)
        #expect(expanded == Fake.pin)
        #expect(router.requests == ["GET https://api.pinterest.com/url_shortener/abc123/redirect/"])

        let (board, _) = Fake.source { _ in
            .init(status: 302, headers: ["Location": "https://www.pinterest.com/someone/"])
        }
        await #expect(throws: NabError.self) { try await board.expand(URL(string: "https://pin.it/abc123")!) }
    }

    // MARK: What a pin holds

    @Test func aPhotoKeepsTheAddressPinterestGaveForItsOriginal() async throws {
        let png = Fake.image("originals", 2, "png")
        let busy = BusyOnce()
        let (source, router) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            if busy.take() { return .init(status: 429) }
            return Fake.api([
                "id": "111222333", "title": "", "grid_title": "Invented cover",
                "description": "First line\nSecond line",
                "pinner": ["username": "maker_one", "full_name": "Maker One"],
                "images": [
                    "orig": ["url": png, "width": 1000, "height": 1500], "736x": ["url": Fake.image("736x", 2)],
                ],
            ])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [png])
        #expect(capture.media.first?.kind == .image)
        #expect(capture.media.first?.width == 1000 && capture.media.first?.height == 1500)
        #expect(capture.title == "Invented cover")
        #expect(capture.summary == "First line\nSecond line")
        #expect(capture.author == "Maker One")
        #expect(capture.authorURL?.absoluteString == "https://www.pinterest.com/maker_one/")
        #expect(capture.thumbnailURL?.absoluteString == png)
        #expect(capture.sourceID == "111222333" && capture.url == Fake.pin)
        #expect(router.count("GET") == 2, "a busy answer is asked again")
    }

    @Test func aVideoTakesTheMp4NotTheStream() async throws {
        let mp4 = Fake.clip("720p", 3)
        let (source, router) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            return Fake.api([
                "id": "111222333", "grid_title": "Invented clip",
                "videos": [
                    "video_list": [
                        "V_720P": Fake.entry(mp4, ms: 57700),
                        "V_HLSV4": Fake.entry(Fake.clip("hls", 3, ext: "m3u8"), ms: 57700),
                    ]
                ],
                "images": ["orig": ["url": Fake.image("originals", 4), "width": 736, "height": 1308]],
            ])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [mp4])
        #expect(capture.media.first?.kind == .video)
        #expect(capture.media.first?.duration == 57.7)
        #expect(capture.duration == 57.7)
        #expect(capture.thumbnailURL?.absoluteString == Fake.image("originals", 4))
        #expect(router.count("HEAD") == 0, "one mp4 needs no size check")
    }

    @Test func anIdeaPinIsItsClipsAndPhotosInOrderWithoutTheMusic() async throws {
        let (source, router) = Fake.source { request in
            if request.httpMethod == "HEAD" {
                let big = request.url?.path().contains("/720p/") == true
                return .init(status: 200, headers: ["Content-Length": big ? "417464" : "195148"])
            }
            guard Fake.isAPI(request) else { return nil }
            let signature = Fake.hash(77)
            let pages: [[String: Any]] = (0..<5).map { page in
                var blocks: [[String: Any]] = []
                if page == 0 {
                    blocks.append([
                        "type": "story_pin_image_block", "image_signature": signature, "image": ["images": [:]],
                    ])
                    blocks.append([
                        "type": "story_pin_static_sticker_block", "text": "sticker words",
                        "image": ["images": ["originals": ["url": Fake.image("originals", 78)]]],
                    ])
                }
                blocks.append(["type": "story_pin_video_block", "video": Fake.ideaClip(10 + page)])
                blocks.append([
                    "type": "story_pin_music_block",
                    "audio": ["audio_url": "https://v1.pinimg.com/audios/mp3/aa/bb/cc/song.mp3"],
                    "image": ["images": ["originals": ["url": Fake.image("originals", 79)]]],
                ])
                if page == 2 { blocks.append(["type": "story_pin_paragraph_block", "text": "Step three"]) }
                return ["blocks": blocks]
            }
            return Fake.api([
                "id": "111222333", "title": "Invented idea", "description": " ",
                "auto_alt_text": "a hand holding a pencil",
                "story_pin_data": ["page_count": 5, "pages": pages],
                "images": ["orig": ["url": Fake.image("originals", 5), "width": 1080, "height": 1920]],
            ])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.kind) == [.image] + Array(repeating: Media.Kind.video, count: 5))
        #expect(capture.media[0].url.absoluteString == Fake.image("originals", 77))
        #expect(capture.media.dropFirst().map(\.url.absoluteString) == (10..<15).map { Fake.clip("720p", $0) })
        #expect(!capture.media.contains { $0.url.pathExtension == "mp3" })
        #expect(capture.summary == "a hand holding a pencil\n\nStep three")
        #expect(capture.duration == 20)
        #expect(router.count("HEAD") == 15, "three mp4 copies of each of five clips")
    }

    @Test func aCarouselIsItsSlidesAtOriginalSize() async throws {
        let (source, _) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            return Fake.api([
                "id": "111222333", "title": "Invented slides",
                "carousel_data": [
                    "carousel_slots": [
                        ["images": ["736x": ["url": Fake.image("736x", 20), "width": 736, "height": 900]]],
                        ["images": ["236x": ["url": Fake.image("236x", 21), "width": 236, "height": 300]]],
                    ]
                ],
                "images": ["orig": ["url": Fake.image("originals", 22), "width": 736, "height": 900]],
            ])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [Fake.image("originals", 20), Fake.image("originals", 21)])
    }

    @Test func aClipOfferedOnlyAsAStreamSaysSo() async throws {
        let (source, _) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            return Fake.api([
                "id": "111222333",
                "videos": ["video_list": ["V_HLSV4": Fake.entry(Fake.clip("hls", 30, ext: "m3u8"))]],
            ])
        }
        do {
            _ = try await source.fetch(Fake.pin)
            Issue.record("a stream-only clip must not be fetched as a photo")
        } catch {
            #expect(error.localizedDescription == "This clip is only offered as a stream Nab can't save yet.")
        }
    }

    // MARK: When the API says no

    @Test func aRefusedApiFallsBackToThePagesClip() async throws {
        let mp4 = Fake.clip("720p", 40)
        let page = """
            <html><head><meta property="og:image" content="\(Fake.image("736x", 41))"/>
            <script data-test="x" type="application/ld+json">{"@type":"SocialMediaPosting","author":{"@type":"Person","name":"Page Maker","alternateName":"page_maker"},"headline":"Page headline","articleBody":"| Page words","image":"\(Fake.image("originals", 41))"}</script>
            <script type="application/ld+json">{"@type":"VideoObject","name":"Page clip","duration":"PT1M5S","width":"1080 px","height":"1920 px","contentUrl":"\(mp4)","thumbnailUrl":"\(Fake.image("originals", 42))"}</script>
            </head></html>
            """
        let (source, router) = Fake.source { request in
            Fake.isAPI(request) ? .init(status: 403) : Fake.html(page)
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [mp4])
        #expect(capture.media.first?.duration == 65 && capture.media.first?.width == 1080)
        #expect(capture.title == "Page clip")
        #expect(capture.summary == "Page words")
        #expect(capture.author == "Page Maker")
        #expect(capture.authorURL?.absoluteString == "https://www.pinterest.com/page_maker/")
        #expect(capture.thumbnailURL?.absoluteString == Fake.image("originals", 42))
        #expect(router.requests.last == "GET https://www.pinterest.com/pin/111222333/")
    }

    @Test func aPageWithOnlyAPreviewGivesThePreview() async throws {
        let preview = Fake.image("736x", 50)
        let page = "<html><head><meta content=\"\(preview)\" property=\"og:image\"/></head></html>"
        for api in [PinterestStub.Reply(status: 403), Fake.api(nil)] {
            let (source, _) = Fake.source { request in Fake.isAPI(request) ? api : Fake.html(page) }
            let capture = try await source.fetch(Fake.pin)
            #expect(capture.media.map(\.url.absoluteString) == [preview])
            #expect(capture.title == "Pinterest pin")
        }
    }

    // MARK: Choosing and trusting

    @Test func theLargestFileWinsOverTheNamePinterestGaveIt() async throws {
        let (source, _) = Fake.source { request in
            if request.httpMethod == "HEAD" {
                let small = request.url?.path().contains("/720p/") == true
                return .init(status: 200, headers: ["Content-Length": small ? "1000" : "9000000"])
            }
            guard Fake.isAPI(request) else { return nil }
            return Fake.api(["id": "111222333", "videos": ["video_list": Fake.ideaClip(60)["video_list"]!]])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [Fake.clip("expMp4", 60, suffix: "_t4")])
    }

    @Test func withoutSizesTheNamesDecide() {
        func variant(_ name: String) -> PinterestPin.Variant {
            .init(name: name, url: URL(string: Fake.clip("720p", 61))!)
        }
        let all = ["V_EXP3", "V_EXP6", "V_720P", "V_EXP7", "V_EXP4"].map(variant)
        #expect(PinterestPin.choose(all, sizes: [:])?.name == "V_EXP7")
        #expect(PinterestPin.choose(all.filter { $0.name != "V_EXP7" }, sizes: [:])?.name == "V_720P")
        #expect(
            PinterestPin.choose(all.filter { $0.name.hasPrefix("V_EXP") && $0.name != "V_EXP7" }, sizes: [:])?.name
                == "V_EXP6")
        #expect(PinterestPin.choose(all, sizes: ["V_EXP3": 5, "V_EXP4": 9])?.name == "V_EXP4")
    }

    @Test func addressesOutsidePinimgAreNeverTrusted() async throws {
        let good = Fake.clip("720p", 70)
        let (source, _) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            return Fake.api([
                "id": "111222333",
                "videos": [
                    "video_list": [
                        "V_EXP7": Fake.entry("https://v1.pinimg.com.evil.test/videos/mc/720p/x.mp4"),
                        "V_720P": Fake.entry("http://v1.pinimg.com/videos/mc/720p/y.mp4"),
                        "V_EXP3": Fake.entry(good, w: 99_999_999, h: -4),
                    ]
                ],
            ])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [good])
        #expect(capture.media.first?.width == nil && capture.media.first?.height == nil)

        let (foreign, _) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            return Fake.api(["id": "1", "images": ["orig": ["url": "https://evil.test/originals/a.jpg"]]])
        }
        await #expect(throws: NabError.self) { try await foreign.fetch(Fake.pin) }
    }

    @Test func titlesAndSummariesFallBackStepByStep() throws {
        let image: [String: Any] = ["orig": ["url": Fake.image("originals", 80)]]
        func read(_ data: [String: Any]) throws -> PinterestPin {
            try PinterestPin.parse(api: data.merging(["images": image]) { $1 })
        }

        let described = try read(["description": "  Line one\nLine two  ", "seo_alt_text": "alt"])
        #expect(described.title == "Line one")
        #expect(described.summary == "Line one\nLine two")
        let alt = try read(["description": " ", "auto_alt_text": "", "seo_alt_text": "a seo text"])
        #expect(alt.title == "Pinterest pin")
        #expect(alt.summary == "a seo text")
        let named = try read([
            "title": "Own title", "grid_title": "Grid", "pinner": ["username": "who", "full_name": ""],
        ])
        #expect(named.title == "Own title" && named.author == "who")
        let bare = try read([:])
        #expect(bare.summary == nil && bare.author == nil && bare.authorURL == nil)
    }

    // MARK: Saving

    @Test func aRefusedOriginalFallsBackToTheSmallerCopies() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let direct = URL(string: Fake.image("736x", 90))!
        let (source, router) = Fake.source { request in
            let path = request.url?.path() ?? ""
            if path.hasPrefix("/originals/") || path.hasPrefix("/1200x/") { return .init(status: 403) }
            return .init(status: 200, body: Data(repeating: 7, count: 321))
        }
        let capture = try await source.fetch(direct)
        #expect(capture.media.map(\.url.absoluteString) == [Fake.image("originals", 90)])
        #expect(capture.title == "Pinterest image")
        try await source.save(capture.media[0], of: capture, to: folder.appending(path: "a.jpg"), progress: { _, _ in })
        let written = try Data(contentsOf: folder.appending(path: "a.jpg"))
        #expect(written.count == 321)
        #expect(
            router.requests.map { URL(string: String($0.dropFirst(4)))!.pathComponents[1] } == [
                "originals", "1200x", "736x",
            ])
    }
}

/// Answers "busy" exactly once.
private final class BusyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var spent = false
    func take() -> Bool {
        lock.withLock {
            defer { spent = true }
            return !spent
        }
    }
}
