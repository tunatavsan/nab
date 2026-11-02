import Foundation
import ImageIO
import NabCore
import Testing
import UniformTypeIdentifiers

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
        if reply.status == 0 { return }  // never answers: a download that stalls
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(reply.body.count)" }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300..<400).contains(reply.status), let location = headers["Location"].flatMap(URL.init(string:)) {
            // A real redirect: the session asks its delegate whether to follow it.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
            // If the delegate refuses to follow, the redirect itself is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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

    static func streamClip(_ n: Int) -> [String: Any] {
        ["video_list": ["V_HLSV3_MOBILE": entry(clip("hls", n, ext: "m3u8"))]]
    }

    static func api(_ data: [String: Any]?) -> PinterestStub.Reply {
        let body: [String: Any] = ["resource_response": ["status": "success", "data": data as Any]]
        return PinterestStub.Reply(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
    }

    static func html(_ text: String) -> PinterestStub.Reply {
        PinterestStub.Reply(status: 200, body: Data(text.utf8))
    }

    static func isAPI(_ request: URLRequest) -> Bool { request.url?.path() == "/resource/PinResource/get/" }

    static func source(
        backoff: Duration = .milliseconds(1), _ handler: @escaping @Sendable (URLRequest) -> PinterestStub.Reply?
    ) -> (PinterestSource, PinterestStub.Router) {
        let (session, router) = PinterestStub.session(handler)
        let downloader = MediaDownloader(session: session, attempts: 1, backoff: .milliseconds(1))
        return (PinterestSource(session: session, downloader: downloader, backoff: backoff), router)
    }

    /// The pin id an API request asks for.
    static func askedID(_ request: URLRequest) -> String {
        let query = request.url?.query(percentEncoded: false) ?? ""
        return query.split(separator: "\"").first { $0.allSatisfy(\.isNumber) && $0.count > 3 }.map(String.init) ?? ""
    }

    /// A real, tiny JPEG.
    static func jpeg() -> Data {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static let pin = URL(string: "https://www.pinterest.com/pin/111222333/")!
}

@Suite("Pinterest")
struct PinterestTests {
    // MARK: Links

    @Test func recognisesEveryShapeOfPinLink() {
        let source = PinterestSource()
        for link in [
            "https://www.pinterest.com/pin/700100200300400500/",
            "https://pinterest.com/pin/700100200300400500",
            "https://tr.pinterest.com/pin/some-title-here--700100200300400500/",
            "https://www.pinterest.co.uk/pin/700100200300400500/",
            "https://uk.pinterest.com/pin/700100200300400500/",
            "https://www.pinterest.com/pin/700100200300400500/sent/?invite_code=abc123&sfo=1",
            "http://www.pinterest.fr/pin/700100200300400500/?utm_source=x",
        ] {
            #expect(source.identify(URL(string: link)!) == "700100200300400500", "\(link)")
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
            "https://notpinterest.com/pin/700100200300400500/", "https://pinterest.co.uk.ab/pin/700100200300400500/",
            "https://pinterest.com.evil.test/pin/700100200300400500/",
            "https://www.pinterest.com/pin/abc--/", "https://i.pinimg.com/736x/not/a/hash.jpg",
            "https://example.com/pin/700100200300400500/", "https://www.youtube.com/watch?v=8jPQjjsBbIc",
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
        #expect(
            router.requests == ["GET https://api.pinterest.com/url_shortener/abc123/redirect/"],
            "the redirect is read, never followed")

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
        #expect(router.count("HEAD") == 16, "three mp4 copies of each of five clips, and the guessed photo")
    }

    @Test func aCarouselIsItsSlidesAtOriginalSize() async throws {
        let (source, _) = Fake.source { request in
            if request.httpMethod == "HEAD" {
                // The second slide's original is a PNG: the guessed .jpg is refused.
                let wrong = request.url?.path().contains(Fake.hash(21)) == true && request.url?.pathExtension == "jpg"
                return .init(status: wrong ? 403 : 200)
            }
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
        #expect(
            capture.media.map(\.url.absoluteString) == [
                Fake.image("originals", 20), Fake.image("originals", 21, "png"),
            ])
    }

    @Test func aClipOfferedOnlyAsAStreamSaysSo() async throws {
        let (source, _) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            return Fake.api([
                "id": "111222333",
                "videos": ["video_list": ["V_HLSV4": Fake.entry(Fake.clip("hls", 30, ext: "m3u8"))]],
                "images": ["orig": ["url": Fake.image("originals", 31), "width": 736, "height": 1308]],
            ])
        }
        let sentence = "This clip is only offered as a stream Nab can't save yet."
        do {
            _ = try await source.fetch(Fake.pin)
            Issue.record("a stream-only clip must not be fetched as its cover photo")
        } catch {
            #expect(error.localizedDescription == sentence)
        }

        let (idea, _) = Fake.source { request in
            guard Fake.isAPI(request) else { return nil }
            let pages = (0..<3).map { page in
                ["blocks": [["type": "story_pin_video_block", "video": Fake.streamClip(32 + page)]]]
            }
            return Fake.api([
                "id": "111222333", "story_pin_data": ["pages": pages],
                "images": ["orig": ["url": Fake.image("originals", 31), "width": 736, "height": 1308]],
            ])
        }
        do {
            _ = try await idea.fetch(Fake.pin)
            Issue.record("an idea pin of streams must not be fetched as its cover photo")
        } catch {
            #expect(error.localizedDescription == sentence)
        }
    }

    @Test func partlyStreamOnlyPinIsSavedWithANoteSayingWhatIsMissing() async throws {
        let (source, _) = Fake.source { request in
            if request.httpMethod == "HEAD" { return .init(status: 200, headers: ["Content-Length": "5000"]) }
            guard Fake.isAPI(request) else { return nil }
            let pages = (0..<5).map { page -> [String: Any] in
                let clip = page == 1 || page == 3 ? Fake.streamClip(40 + page) : Fake.ideaClip(40 + page)
                return ["blocks": [["type": "story_pin_video_block", "video": clip]]]
            }
            return Fake.api(["id": "111222333", "title": "Invented idea", "story_pin_data": ["pages": pages]])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.count == 3)
        #expect(capture.note == "2 of 5 clips can't be saved")
        #expect(RackText.kindLine(capture) == "3 videos · 2 of 5 clips can't be saved")
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
        let others = all.filter { ["V_EXP3", "V_EXP4"].contains($0.name) }
        #expect(PinterestPin.choose(others, sizes: ["V_EXP3": 5, "V_EXP4": 9])?.name == "V_EXP4")
    }

    @Test func aCopyWhoseSizeIsUnknownStaysInTheRunningWhenItsNameRanksHigher() {
        func variant(_ name: String) -> PinterestPin.Variant {
            .init(name: name, url: URL(string: Fake.clip("720p", 62))!)
        }
        let all = ["V_EXP3", "V_EXP6", "V_EXP7"].map(variant)
        #expect(PinterestPin.choose(all, sizes: ["V_EXP3": 195_148, "V_EXP6": 322_254])?.name == "V_EXP7")
        #expect(PinterestPin.choose(all, sizes: ["V_EXP3": 195_148, "V_EXP7": 417_464])?.name == "V_EXP7")
        #expect(PinterestPin.choose(all, sizes: ["V_EXP3": 900, "V_EXP6": 9_000, "V_EXP7": 100])?.name == "V_EXP6")
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

    @Test func aDirectLinkIsFoundAtItsLargestCopyAndNamedForWhatItIs() async throws {
        let link = URL(string: Fake.image("736x", 90))!
        let (png, router) = Fake.source { request in
            let wrong = request.url?.pathComponents[1] == "originals" && request.url?.pathExtension == "jpg"
            return .init(status: wrong ? 403 : 200)
        }
        let capture = try await png.fetch(link)
        #expect(capture.media.map(\.url.absoluteString) == [Fake.image("originals", 90, "png")])
        #expect(capture.title == Fake.hash(90))
        #expect(MediaFileName.names(for: capture, sourceName: "Pinterest").first?.hasSuffix(".png") == true)
        #expect(
            router.requests.map { URL(string: String($0.dropFirst(5)))!.lastPathComponent.suffix(3) } == ["jpg", "png"])

        let (small, _) = Fake.source { request in .init(status: request.url?.pathComponents[1] == "736x" ? 200 : 403) }
        let capture2 = try await small.fetch(link)
        #expect(capture2.media.map(\.url.absoluteString) == [Fake.image("736x", 90)])

        let (none, _) = Fake.source { _ in .init(status: 403) }
        await #expect(throws: NabError.self) { try await none.fetch(link) }
    }

    @Test func aRefusedOriginalFallsBackToTheSmallerCopiesWhenSaving() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (source, router) = Fake.source { request in
            let path = request.url?.path() ?? ""
            if path.hasPrefix("/originals/") || path.hasPrefix("/1200x/") { return .init(status: 403) }
            return .init(status: 200, body: Data(repeating: 7, count: 321))
        }
        let media = Media(kind: .image, url: URL(string: Fake.image("originals", 91))!)
        let capture = Capture(
            source: .pinterest, sourceID: "1", url: Fake.pin, title: "t", media: [media])
        try await source.save(media, of: capture, to: folder.appending(path: "a.jpg"), progress: { _, _ in })
        #expect(try Data(contentsOf: folder.appending(path: "a.jpg")).count == 321)
        #expect(
            router.requests.map { URL(string: String($0.dropFirst(4)))!.pathComponents[1] } == [
                "originals", "1200x", "736x",
            ])
    }

    @Test(.timeLimit(.minutes(1))) func downloadsInProgressDoNotHoldBackTheNextPin() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (source, _) = Fake.source { request in
            if request.url?.host() == "i.pinimg.com" { return .init(status: 0) }  // the download never ends
            guard Fake.isAPI(request) else { return nil }
            return Fake.api([
                "id": "111222333", "title": "Next pin",
                "images": ["orig": ["url": Fake.image("originals", 92, "png"), "width": 10, "height": 10]],
            ])
        }
        let media = Media(kind: .image, url: URL(string: Fake.image("originals", 93, "png"))!)
        let capture = Capture(source: .pinterest, sourceID: "1", url: Fake.pin, title: "t", media: [media])
        // More downloads than the details gate has places (8): if saving held a place, none would be left.
        let saves = (0..<10).map { index in
            Task {
                try await source.save(
                    media, of: capture, to: folder.appending(path: "s\(index).png"), progress: { _, _ in })
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let title = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await source.fetch(Fake.pin).title }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw NabError("the next pin was held back by downloads")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(title == "Next pin")
        for save in saves { save.cancel() }
    }

    @Test func aNoteSurvivesTheLibraryFileAndOldFilesStillOpen() throws {
        var capture = Capture(source: .pinterest, sourceID: "1", url: Fake.pin, title: "t")
        capture.note = "1 of 2 clips can't be saved"
        let data = try JSONEncoder().encode(capture)
        #expect(try JSONDecoder().decode(Capture.self, from: data).note == capture.note)

        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["note"] = nil
        let reopened = try JSONDecoder().decode(Capture.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(reopened.note == nil)
    }

    @Test func pinterestSessionsRefuseCookies() {
        for config in [
            URLSession.nab.configuration, PinterestSource.cookielessDetails.configuration,
        ].map({ PinterestSource.cookieless($0) }) {
            #expect(!config.httpShouldSetCookies)
            #expect(config.httpCookieAcceptPolicy == .never)
            #expect(config.httpCookieStorage == nil)
        }
        #expect(!PinterestSource.cookielessDetails.configuration.httpShouldSetCookies)
        #expect(PinterestSource.cookielessDetails.configuration.httpCookieStorage == nil)
    }
}

extension PinterestTests {
    @Test func aPageWhoseClipIsOnlyAStreamSaysSoInsteadOfGivingItsCover() async throws {
        let cover = Fake.image("736x", 100)
        let page = """
            <html><head><meta property="og:image" content="\(cover)"/>
            <script type="application/ld+json">{"@type":"SocialMediaPosting","headline":"h","image":"\(Fake.image("originals", 100))"}</script>
            <script type="application/ld+json">{"@type":"VideoObject","name":"n","contentUrl":"\(Fake.clip("hls", 100, ext: "m3u8"))"}</script>
            </head></html>
            """
        let (source, _) = Fake.source { request in Fake.isAPI(request) ? .init(status: 403) : Fake.html(page) }
        do {
            _ = try await source.fetch(Fake.pin)
            Issue.record("a stream-only page must not be saved as its cover photo")
        } catch {
            #expect(error.localizedDescription == "This clip is only offered as a stream Nab can't save yet.")
        }
    }

    @Test func aCopyThatTheServerRefusesIsNotChosen() async throws {
        let (source, _) = Fake.source { request in
            if request.httpMethod == "HEAD" {
                let path = request.url?.path() ?? ""
                if path.contains("/720p/") { return .init(status: 403) }
                return .init(status: 200, headers: ["Content-Length": path.contains("_t4") ? "9000" : "100"])
            }
            guard Fake.isAPI(request) else { return nil }
            return Fake.api(["id": "111222333", "videos": ["video_list": Fake.ideaClip(101)["video_list"]!]])
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.map(\.url.absoluteString) == [Fake.clip("expMp4", 101, suffix: "_t4")])
    }

    @Test func aClipRefusedWhenSavingDropsToTheNextCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (source, router) = Fake.source { request in
            let path = request.url?.path() ?? ""
            if request.httpMethod == "HEAD" {
                let size = path.contains("/720p/") ? "9000" : path.contains("_t4") ? "5000" : "100"
                return .init(status: 200, headers: ["Content-Length": size])
            }
            if Fake.isAPI(request) {
                return Fake.api(["id": "111222333", "videos": ["video_list": Fake.ideaClip(102)["video_list"]!]])
            }
            return path.contains("/720p/")
                ? .init(status: 403) : .init(status: 200, body: Data(repeating: 3, count: 77))
        }
        let capture = try await source.fetch(Fake.pin)
        #expect(capture.media.first?.url.absoluteString == Fake.clip("720p", 102))
        let file = folder.appending(path: "clip.mp4")
        try await source.save(capture.media[0], of: capture, to: file, progress: { _, _ in })
        #expect(try Data(contentsOf: file).count == 77)
        #expect(router.requests.filter { $0.hasPrefix("GET https://v1") }.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aBusyWaitHoldsNoPlaceInTheGate() async throws {
        let (source, _) = Fake.source(backoff: .seconds(4)) { request in
            guard Fake.isAPI(request) else { return nil }
            if Fake.askedID(request).hasPrefix("9") { return .init(status: 503) }
            return Fake.api([
                "id": "111222333", "title": "Free pin",
                "images": ["orig": ["url": Fake.image("originals", 103), "width": 10, "height": 10]],
            ])
        }
        // Eight pins that Pinterest says are busy: all eight are waiting out their back-off, not working.
        let busy = (0..<8).map { index in
            Task { try await source.fetch(URL(string: "https://www.pinterest.com/pin/9000000000\(index)/")!) }
        }
        try await Task.sleep(for: .milliseconds(400))
        let title = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await source.fetch(Fake.pin).title }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw NabError("a request was held back by others that were only waiting")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(title == "Free pin")
        for task in busy { task.cancel() }
    }

    @Test func aCopyFetchedInPlaceOfAnotherIsSavedUnderItsOwnType() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = Fake.jpeg()
        // The HEAD said the PNG original is there; the file itself is refused, so the 1200-wide JPEG arrives.
        let (source, _) = Fake.source { request in
            if request.httpMethod == "HEAD" { return .init(status: 200) }
            return request.url?.path().hasPrefix("/originals/") == true
                ? .init(status: 403) : .init(status: 200, body: jpeg)
        }
        let media = Media(kind: .image, url: URL(string: Fake.image("originals", 104, "png"))!)
        let capture = Capture(source: .pinterest, sourceID: "1", url: Fake.pin, title: "t", media: [media])
        let stored = try await source.store(media, of: capture, at: folder.appending(path: "photo (Pinterest 1).png"))
        #expect(stored.savedURL?.pathExtension == "jpg")
        #expect(try Data(contentsOf: #require(stored.savedURL)).prefix(2) == Data([0xFF, 0xD8]))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "photo (Pinterest 1).png").path))
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
