import Foundation
import NabCore

extension SourceKind {
    public static let pinterest = SourceKind(rawValue: "pinterest")
}

/// Reads Pinterest pins without an account: photos, videos, idea pins and carousels, each at the best copy
/// Pinterest hands to a signed-out browser. No cookie is sent, stored or read (its sessions refuse them); a refusal
/// is reported, not worked around. At most eight requests for a pin's details are in flight at once, and a busy
/// answer is waited out, three tries. Saving a file is the downloader's own queue, so a long download never holds
/// back the next pin's details.
public struct PinterestSource: SourceProvider {
    public let kind = SourceKind.pinterest
    public let name = "Pinterest"
    private let session: URLSession
    private let downloader: MediaDownloader
    private let backoff: Duration
    private let gate = Gate(limit: 8)

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let attempts = 3

    /// Pinterest's sessions: the shared ones with cookies switched off, so nothing it sets is ever sent back.
    static let cookielessDetails = URLSession(configuration: cookieless(URLSession.nab.configuration))
    static let cookielessMedia = MediaDownloader(
        session: URLSession(configuration: cookieless(URLSession.nabMedia.configuration)))

    static func cookieless(_ config: URLSessionConfiguration) -> URLSessionConfiguration {
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return config
    }

    public init(session: URLSession? = nil, downloader: MediaDownloader? = nil, backoff: Duration = .milliseconds(800))
    {
        self.session = session ?? Self.cookielessDetails
        self.downloader = downloader ?? Self.cookielessMedia
        self.backoff = backoff
    }

    // MARK: Links

    public func identify(_ url: URL) -> String? {
        PinterestURL.pinID(in: url) ?? PinterestURL.image(in: url)?.hash
    }

    public func isShortLink(_ url: URL) -> Bool { PinterestURL.shortCode(in: url) != nil }

    /// `pin.it/<code>` answers with a redirect; the redirect is read, not followed, so one request names the pin.
    public func expand(_ url: URL) async throws -> URL {
        guard let code = PinterestURL.shortCode(in: url) else { return url }
        guard let target = URL(string: "https://api.pinterest.com/url_shortener/\(code)/redirect/") else {
            return url
        }
        var request = URLRequest(url: target)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await send(request, delegate: StopRedirects())
        switch response.statusCode {
        case 300..<400:
            if let location = response.value(forHTTPHeaderField: "Location"),
                let next = URL(string: location, relativeTo: target)?.absoluteURL,
                let id = PinterestURL.pinID(in: next)
            {
                return PinterestURL.pinURL(id)
            }
            throw NabError("This short link doesn't lead to a Pinterest pin.")
        case 404:
            throw NabError("This Pinterest short link doesn't exist any more.")
        default:
            throw NabError("Pinterest answered HTTP \(response.statusCode) for this short link.")
        }
    }

    // MARK: Fetching

    public func fetch(_ url: URL) async throws -> Capture {
        if isShortLink(url) { return try await fetch(try await expand(url)) }
        if let image = PinterestURL.image(in: url) { return try await capture(of: image, from: url) }
        guard let id = PinterestURL.pinID(in: url) else { throw NabError("Not a Pinterest pin link.") }
        let pin = try await load(id)
        let media = try await resolve(pin.slots)
        let durations = media.compactMap(\.duration)
        return Capture(
            source: .pinterest, sourceID: id, url: PinterestURL.pinURL(id), title: pin.title, author: pin.author,
            authorURL: pin.authorURL, duration: durations.isEmpty ? nil : durations.reduce(0, +),
            summary: pin.summary, thumbnailURL: pin.thumbnail, media: media, note: pin.note)
    }

    /// A link straight to a photo has no pin around it: just the photo, at the largest copy Pinterest will give,
    /// named for its file. The copy is found now (not when saving), so the address, the file name and the type all
    /// say what will really be on disk.
    private func capture(of image: PinterestURL.Image, from url: URL) async throws -> Capture {
        guard let copy = await bestCopy(of: image) else { throw NabError("Pinterest has no copy of this photo.") }
        return Capture(
            source: .pinterest, sourceID: image.hash, url: url,
            title: url.deletingPathExtension().lastPathComponent, thumbnailURL: url,
            media: [Media(kind: .image, url: copy)])
    }

    /// The first copy that answers, largest first: `originals` in the link's own extension, then the other
    /// extensions Pinterest keeps originals in (a wrong one is a 403), then 1200 wide, then 736.
    private func bestCopy(of image: PinterestURL.Image) async -> URL? {
        var seen = Set<String>()
        let extensions = ([image.ext] + ["jpg", "png", "webp", "gif"]).filter { seen.insert($0).inserted }
        let candidates =
            extensions.compactMap { PinterestURL.imageURL(size: "originals", hash: image.hash, ext: $0) }
            + ["1200x", "736x"].compactMap { PinterestURL.imageURL(size: $0, hash: image.hash, ext: "jpg") }
        for candidate in candidates where await head(candidate) != nil { return candidate }
        return nil
    }

    /// The pin from the API; from its page when the API refuses or answers with nothing.
    private func load(_ id: String) async throws -> PinterestPin {
        let (body, response) = try await send(Self.apiRequest(id))
        if response.statusCode == 404 { throw Self.gone }
        if response.statusCode == 200, !body.isEmpty {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? PinterestPin.JSON else {
                throw PinterestPin.changed
            }
            if let data = (json["resource_response"] as? PinterestPin.JSON)?["data"] as? PinterestPin.JSON,
                !data.isEmpty
            {
                return try PinterestPin.parse(api: data)
            }
        }
        var page = URLRequest(url: PinterestURL.pinURL(id))
        page.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        page.setValue("text/html", forHTTPHeaderField: "Accept")
        let (html, answer) = try await send(page)
        if answer.statusCode == 404 { throw Self.gone }
        guard answer.statusCode == 200 else {
            throw NabError("Pinterest refused this pin (HTTP \(answer.statusCode)). Try again later.")
        }
        return try PinterestPin.parse(html: String(decoding: html, as: UTF8.self))
    }

    static let gone = NabError("This pin is gone or private.")

    static func apiRequest(_ id: String) -> URLRequest {
        let options = #"{"options":{"id":"\#(id)","field_set_key":"unauth_react_main_pin"}}"#
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = options.addingPercentEncoding(withAllowedCharacters: allowed) ?? options
        var request = URLRequest(
            url: URL(string: "https://www.pinterest.com/resource/PinResource/get/?data=\(encoded)")!)
        request.setValue("www/[username].js", forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Picks the best copy of each clip (the largest file, asked of the server with a HEAD) and keeps the order.
    private func resolve(_ slots: [PinterestPin.Slot]) async throws -> [Media] {
        try await withThrowingTaskGroup(of: (Int, Media).self) { group in
            for (index, slot) in slots.enumerated() {
                group.addTask {
                    switch slot {
                    case .image(let media): return (index, media)
                    case .guessed(let media):
                        guard let image = PinterestURL.image(in: media.url), let copy = await self.bestCopy(of: image)
                        else { return (index, media) }
                        var found = media
                        found.url = copy
                        return (index, found)
                    case .video(let variants):
                        guard let best = await self.best(of: variants) else { throw PinterestPin.changed }
                        return (
                            index,
                            Media(
                                kind: .video, url: best.url, width: best.width, height: best.height,
                                duration: best.durationMS.map { Double($0) / 1000 })
                        )
                    }
                }
            }
            var found: [(Int, Media)] = []
            for try await item in group { found.append(item) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func best(of variants: [PinterestPin.Variant]) async -> PinterestPin.Variant? {
        if variants.count == 1 { return variants.first }
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?).self) { group in
            for variant in variants {
                group.addTask { (variant.name, await self.length(of: variant.url)) }
            }
            for await (name, size) in group { if let size { sizes[name] = size } }
        }
        return PinterestPin.choose(variants, sizes: sizes)
    }

    /// The answer to a HEAD when the address is there (2xx), else nil.
    private func head(_ url: URL) async -> HTTPURLResponse? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await send(request), (200..<300).contains(response.statusCode) else {
            return nil
        }
        return response
    }

    private func length(of url: URL) async -> Int64? {
        guard let text = await head(url)?.value(forHTTPHeaderField: "Content-Length"), let size = Int64(text), size > 0
        else { return nil }
        return size
    }

    // MARK: Saving

    /// The photo at its original size; when Pinterest refuses that (the file's real extension differs from the
    /// one guessed), the same picture at 1200 wide, then at 736.
    public func save(
        _ media: Media, of capture: Capture, to file: URL,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws {
        var urls = [media.url]
        if media.kind == .image, let image = PinterestURL.image(in: media.url),
            media.url.pathComponents.dropFirst().first == "originals"
        {
            urls += ["1200x", "736x"].compactMap { PinterestURL.imageURL(size: $0, hash: image.hash, ext: "jpg") }
        }
        let headers = ["User-Agent": Self.userAgent]
        for (index, url) in urls.enumerated() {
            do {
                // The downloader has its own queue; holding the details gate here would stall every new pin behind
                // the slowest download.
                try await downloader.download(url, to: file, headers: headers, progress: progress)
                return
            } catch let error as HTTPStatusError where error.status == 403 && index < urls.count - 1 {
                continue
            }
        }
        throw HTTPStatusError(status: 403)
    }

    // MARK: Requests

    private func send(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (
        Data, HTTPURLResponse
    ) {
        try await gate.run {
            var attempt = 1
            while true {
                let (data, response) = try await session.data(for: request, delegate: delegate)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if [429, 503].contains(http.statusCode), attempt < Self.attempts {
                    try await Task.sleep(for: backoff * (1 << (attempt - 1)))
                    attempt += 1
                    continue
                }
                return (data, http)
            }
        }
    }
}

/// Hands back the redirect itself instead of following it.
private final class StopRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
