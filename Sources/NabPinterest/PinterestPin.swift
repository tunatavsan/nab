import Foundation
import NabCore

/// What one pin says, read out of Pinterest's JSON or, failing that, its page. Pure: no request is made here, and
/// everything remote is treated as untrusted (hosts checked, numbers bounded, shapes not assumed).
struct PinterestPin: Sendable {
    struct Variant: Sendable, Equatable {
        var name: String
        var url: URL
        var width: Int?
        var height: Int?
        var durationMS: Int?
    }

    enum Slot: Sendable {
        case image(Media)
        /// Every plain `.mp4` copy of one clip; `PinterestPin.choose` picks one.
        case video([Variant])
    }

    var title: String
    var summary: String?
    var author: String?
    var authorURL: URL?
    var thumbnail: URL?
    var slots: [Slot]

    static let changed = NabError("Pinterest changed its page; update Nab.")
    static let streamOnly = NabError("This clip is only offered as a stream Nab can't save yet.")

    // MARK: Choosing

    /// The copy to save: the largest file when the sizes are known, else by name, which is how Pinterest orders
    /// its own renditions (`V_EXP7` is the 720p original, `V_720P` the same on older pins).
    static func choose(_ variants: [Variant], sizes: [String: Int64]) -> Variant? {
        let known = variants.filter { sizes[$0.name] != nil }
        let pool = known.isEmpty ? variants : known
        return pool.max { lhs, rhs in
            let l = (sizes[lhs.name] ?? 0, rank(lhs), area(lhs))
            let r = (sizes[rhs.name] ?? 0, rank(rhs), area(rhs))
            return l < r
        }
    }

    private static func rank(_ variant: Variant) -> Int {
        let name = variant.name.uppercased()
        if name == "V_EXP7" { return 100 }
        if name == "V_720P" { return 90 }
        if name.hasPrefix("V_EXP"), let n = Int(name.dropFirst(5)), (0...79).contains(n) { return 10 + n }
        return 0
    }

    private static func area(_ variant: Variant) -> Int { (variant.width ?? 0) * (variant.height ?? 0) }

    // MARK: Untrusted values

    typealias JSON = [String: Any]

    /// `https` and `pinimg.com` or a subdomain of it; anything else a pin points at is ignored.
    static func safeURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
            url.scheme == "https", let host = url.host()?.lowercased(),
            host == "pinimg.com" || host.hasSuffix(".pinimg.com")
        else { return nil }
        return url
    }

    static func dimension(_ value: Any?) -> Int? {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, (1...20_000).contains(n) else { return nil }
        return Int(n)
    }

    static func milliseconds(_ value: Any?) -> Int? {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, (0...86_400_000).contains(n) else { return nil }
        return Int(n)
    }

    static func text(_ value: Any?, limit: Int = 4000) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return String(s.prefix(limit))
    }

    private static func mediaImage(_ entry: JSON?) -> Media? {
        guard let entry, let url = safeURL(entry["url"]) else { return nil }
        return Media(kind: .image, url: url, width: dimension(entry["width"]), height: dimension(entry["height"]))
    }

    /// Plain `.mp4` copies of a clip, and whether it also (or only) has a stream.
    private static func variants(in list: JSON) -> (mp4: [Variant], stream: Bool) {
        var mp4: [Variant] = []
        var stream = false
        for (name, value) in list.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? JSON, let url = safeURL(entry["url"]) else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "m3u8" || name.uppercased().contains("HLS") {
                stream = true
            } else if ext == "mp4" {
                mp4.append(
                    Variant(
                        name: name, url: url, width: dimension(entry["width"]), height: dimension(entry["height"]),
                        durationMS: milliseconds(entry["duration"])))
            }
        }
        return (mp4, stream)
    }

    private static func poster(in list: JSON) -> URL? {
        list.sorted(by: { $0.key < $1.key }).lazy.compactMap { safeURL(($0.value as? JSON)?["thumbnail"]) }.first
    }

    // MARK: The API's answer

    static func parse(api data: JSON) throws -> PinterestPin {
        var slots: [Slot] = []
        var paragraphs: [String] = []
        var onlyStreams = false
        var poster: URL?

        if let story = data["story_pin_data"] as? JSON {
            var found: [Slot] = []
            var words: [String] = []
            for page in (story["pages"] as? [Any] ?? []).compactMap({ $0 as? JSON }) {
                for block in (page["blocks"] as? [Any] ?? []).compactMap({ $0 as? JSON }) {
                    let type = (block["type"] as? String ?? "").lowercased()
                    if type.contains("music") || type.contains("audio") || type.contains("sticker") { continue }
                    if type.contains("paragraph") {
                        if let line = text(block["text"]) { words.append(line) }
                    } else if let list = (block["video"] as? JSON)?["video_list"] as? JSON {
                        let clip = variants(in: list)
                        if clip.mp4.isEmpty {
                            onlyStreams = onlyStreams || clip.stream
                        } else {
                            found.append(.video(clip.mp4))
                            poster = poster ?? Self.poster(in: list)
                        }
                    } else if let image = block["image"] as? JSON {
                        let originals = mediaImage((image["images"] as? JSON)?["originals"] as? JSON)
                        let signature = text(block["image_signature"]) ?? text(image["image_signature"])
                        if let originals {
                            found.append(.image(originals))
                        } else if let signature,
                            let url = PinterestURL.imageURL(
                                size: "originals", hash: signature, ext: "jpg")
                        {
                            found.append(.image(Media(kind: .image, url: url)))
                        }
                    }
                }
            }
            if !found.isEmpty { (slots, paragraphs) = (found, words) }
        }

        if slots.isEmpty, let carousel = data["carousel_data"] as? JSON {
            for slot in (carousel["carousel_slots"] as? [Any] ?? []).compactMap({ $0 as? JSON }) {
                if let media = carouselImage(slot["images"] as? JSON) { slots.append(.image(media)) }
            }
        }

        if slots.isEmpty, let list = (data["videos"] as? JSON)?["video_list"] as? JSON {
            let found = variants(in: list)
            if found.mp4.isEmpty {
                onlyStreams = onlyStreams || found.stream
            } else {
                slots = [.video(found.mp4)]
                poster = poster ?? Self.poster(in: list)
            }
        }

        let orig = mediaImage((data["images"] as? JSON)?["orig"] as? JSON)
        if slots.isEmpty, let orig { slots = [.image(orig)] }
        if slots.isEmpty { throw onlyStreams ? streamOnly : changed }

        let description = text(data["description"])
        let pinner = data["pinner"] as? JSON
        let username = text(pinner?["username"], limit: 100)
        var pin = PinterestPin(
            title: text(data["title"], limit: 300) ?? text(data["grid_title"], limit: 300)
                ?? description.flatMap {
                    text($0.split(whereSeparator: \.isNewline).first.map(String.init), limit: 200)
                }
                ?? "Pinterest pin",
            summary: nil,
            author: text(pinner?["full_name"], limit: 200) ?? username,
            authorURL: username.flatMap(profileURL),
            thumbnail: orig?.url ?? poster ?? firstImage(in: slots),
            slots: slots)
        let lead = description ?? text(data["auto_alt_text"]) ?? text(data["seo_alt_text"])
        let summary = ([lead] + [paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n")])
            .compactMap { $0 }.joined(separator: "\n\n")
        pin.summary = summary.isEmpty ? nil : summary
        return pin
    }

    /// The slot's copy at the original size: its folder is renamed, since only `originals` is the full picture.
    private static func carouselImage(_ images: JSON?) -> Media? {
        guard let images else { return nil }
        if let originals = mediaImage(images["originals"] as? JSON) { return originals }
        let best = images.values.compactMap { $0 as? JSON }.filter { safeURL($0["url"]) != nil }
            .max { (dimension($0["width"]) ?? 0) < (dimension($1["width"]) ?? 0) }
        guard let best, let url = safeURL(best["url"]) else { return nil }
        let parts = url.pathComponents
        guard parts.count == 6, let image = PinterestURL.image(in: url),
            let full = PinterestURL.imageURL(size: "originals", hash: image.hash, ext: image.ext)
        else { return Media(kind: .image, url: url) }
        return Media(kind: .image, url: full)
    }

    private static func firstImage(in slots: [Slot]) -> URL? {
        slots.lazy.compactMap { slot -> URL? in
            if case .image(let media) = slot { return media.url }
            return nil
        }.first
    }

    private static func profileURL(_ username: String) -> URL? {
        guard username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) else {
            return nil
        }
        return URL(string: "https://www.pinterest.com/\(username)/")
    }

    // MARK: The page, when the API will not answer

    static func parse(html: String) throws -> PinterestPin {
        var title: String?
        var summary: String?
        var author: String?
        var authorURL: URL?
        var image: URL?
        var video: Variant?
        var poster: URL?
        for object in jsonLD(in: html) {
            switch object["@type"] as? String {
            case "VideoObject":
                if let url = safeURL(object["contentUrl"]), url.pathExtension.lowercased() == "mp4" {
                    video = Variant(
                        name: "ld", url: url, width: pixels(object["width"]), height: pixels(object["height"]),
                        durationMS: isoSeconds(object["duration"]).flatMap { milliseconds(NSNumber(value: $0 * 1000)) })
                    poster = safeURL(object["thumbnailUrl"])
                    title = text(object["name"], limit: 300) ?? title
                    summary = text(object["description"]) ?? summary
                }
            case "SocialMediaPosting":
                title = title ?? text(object["headline"], limit: 300)
                let body = text(object["articleBody"])?.trimmingCharacters(in: CharacterSet(charactersIn: "| \n"))
                summary = summary ?? body.flatMap { $0.isEmpty ? nil : $0 }
                image = image ?? safeURL(object["image"])
                if let person = object["author"] as? JSON {
                    let handle = text(person["alternateName"], limit: 100)
                    author = author ?? text(person["name"], limit: 200) ?? handle
                    authorURL = authorURL ?? handle.flatMap(profileURL)
                }
            default: break
            }
        }
        if video == nil, image == nil { image = safeURL(metaContent("og:image", in: html)) }
        title = title ?? text(metaContent("og:title", in: html), limit: 300)
        let slots: [Slot]
        if let video {
            slots = [.video([video])]
        } else if let image {
            slots = [.image(Media(kind: .image, url: image))]
        } else {
            throw changed
        }
        return PinterestPin(
            title: title ?? "Pinterest pin", summary: summary, author: author, authorURL: authorURL,
            thumbnail: poster ?? image, slots: slots)
    }

    private static func jsonLD(in html: String) -> [JSON] {
        guard
            let scripts = try? NSRegularExpression(
                pattern: #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#,
                options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        return scripts.matches(in: html, range: whole).flatMap { match -> [JSON] in
            guard let range = Range(match.range(at: 1), in: html),
                let json = try? JSONSerialization.jsonObject(with: Data(html[range].utf8))
            else { return [] }
            return (json as? [Any] ?? [json]).compactMap { $0 as? JSON }
        }
    }

    private static func metaContent(_ property: String, in html: String) -> String? {
        guard let tags = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive),
            let content = try? NSRegularExpression(pattern: #"content=["']([^"']*)["']"#, options: .caseInsensitive)
        else { return nil }
        for tag in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(tag.range, in: html) else { continue }
            let text = String(html[range])
            guard text.contains("\"\(property)\"") || text.contains("'\(property)'"),
                let hit = content.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let value = Range(hit.range(at: 1), in: text)
            else { continue }
            return text[value].replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    /// `"1080 px"` → 1080.
    private static func pixels(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return dimension(number) }
        guard let text = value as? String else { return nil }
        return Int(text.prefix { $0.isNumber }).flatMap { dimension(NSNumber(value: $0)) }
    }

    /// `PT1M5S` → 65.
    private static func isoSeconds(_ value: Any?) -> Double? {
        guard let text = value as? String, text.hasPrefix("PT") else { return nil }
        var total = 0.0
        var number = ""
        for c in text.dropFirst(2) {
            if c.isNumber || c == "." {
                number.append(c)
            } else if let n = Double(number), let unit = ["H": 3600.0, "M": 60.0, "S": 1.0][String(c)] {
                total += n * unit
                number = ""
            } else {
                return nil
            }
        }
        return total
    }
}
