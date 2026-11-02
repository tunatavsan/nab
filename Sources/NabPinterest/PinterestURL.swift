import Foundation

/// What a link names, worked out from the link alone: no request, no state.
enum PinterestURL {
    /// A photo Pinterest hosts directly: `i.pinimg.com/<size>/xx/yy/zz/<hash>.<ext>`.
    struct Image: Equatable {
        var hash: String
        var ext: String
    }

    /// `pinterest.com`, a region (`tr.pinterest.com`) or a country site (`www.pinterest.co.uk`); never a host that
    /// merely contains the word.
    static func isPinterestHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard let at = labels.firstIndex(of: "pinterest"), at <= 1 else { return false }
        let tld = labels[(at + 1)...]
        return (1...2).contains(tld.count) && tld.allSatisfy { (2...3).contains($0.count) && $0.allSatisfy(\.isLetter) }
    }

    /// The pin id of `/pin/<id>`, `/pin/<slug>--<id>/` and `/pin/<id>/sent/?invite_code=…`.
    static func pinID(in url: URL) -> String? {
        guard let host = url.host(), isPinterestHost(host) else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "pin" else { return nil }
        let id = parts[2].components(separatedBy: "--").last ?? ""
        return (1...25).contains(id.count) && id.allSatisfy(\.isASCII) && id.allSatisfy(\.isNumber) ? id : nil
    }

    /// The code of `pin.it/<code>`.
    static func shortCode(in url: URL) -> String? {
        guard let host = url.host()?.lowercased(), host == "pin.it" || host == "www.pin.it" else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 2, parts.count <= 3, (3...40).contains(parts[1].count),
            parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return parts[1]
    }

    static func image(in url: URL) -> Image? {
        guard url.host()?.lowercased() == "i.pinimg.com" else { return nil }
        let parts = url.pathComponents
        guard parts.count == 6 else { return nil }
        let size = parts[1]
        guard
            size == "originals"
                || (size.contains("x") && size.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        guard parts[2...4].allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        let file = parts[5] as NSString
        let hash = file.deletingPathExtension
        let ext = file.pathExtension.lowercased()
        guard (16...64).contains(hash.count), hash.allSatisfy(\.isHexDigit), (2...5).contains(ext.count),
            ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return Image(hash: hash.lowercased(), ext: ext)
    }

    /// `https://i.pinimg.com/<size>/ab/cd/ef/<hash>.<ext>`: the folders are the hash's first three pairs.
    static func imageURL(size: String, hash: String, ext: String) -> URL? {
        guard hash.count >= 6, hash.allSatisfy(\.isHexDigit) else { return nil }
        let h = Array(hash)
        let folders = [h[0..<2], h[2..<4], h[4..<6]].map { String($0) }.joined(separator: "/")
        return URL(string: "https://i.pinimg.com/\(size)/\(folders)/\(hash).\(ext)")
    }

    static func pinURL(_ id: String) -> URL { URL(string: "https://www.pinterest.com/pin/\(id)/")! }
}
