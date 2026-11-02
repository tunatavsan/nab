import Foundation
import NabCore
import NabSources

// nab <link>... — fetches every link in parallel and prints one context pack to stdout.
// The same core the app uses, so agents can read videos and pins without the UI.

func complain(_ message: String) { FileHandle.standardError.write(Data("nab: \(message)\n".utf8)) }

let registry = SourceRegistry.standard
let usage = """
    usage: nab [--json] [--save <folder>] <link>...
      Reads \(RackText.list(registry.names)) links in parallel and prints a context pack for AI: a video's
      details and transcript, or an item's details and its photos and clips.
      --json           print captures as JSON instead (photos and clips under "media")
      --save <folder>  save each item's photos and clips there at full size; the pack lists the saved files
    """

let options: CLIOptions
switch CLIOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): options = parsed
case .failure(let problem):
    complain(problem.message)
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
if options.links.isEmpty || options.help {
    print(usage)
    exit(options.help ? 0 : 64)
}

// The folder is checked before anything is fetched, so a typo does not cost the downloads first.
var saveFolder: URL?
if let typed = options.saveFolder {
    let path = (typed as NSString).expandingTildeInPath
    let folder = URL(filePath: path, directoryHint: .isDirectory, relativeTo: .currentDirectory()).absoluteURL
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw CocoaError(.fileWriteNoPermission) }
    } catch {
        complain("can't save to \(typed): \(error.localizedDescription)")
        exit(1)
    }
    saveFolder = folder
}
let input = options.links

let found = registry.links(in: input.joined(separator: "\n"))
if found.isEmpty {
    complain("no supported links found")
    exit(65)
}
// Share links (pin.it/…) name their item only after one request. Two links to one item (a share link and the
// item's own, or two forms of a video link) are read once, as the app keeps one entry.
var urls: [URL] = []
var seen: Set<String> = []
var expandFailed = false
for url in found {
    do {
        let full = try await registry.expand(url)
        guard let match = registry.match(full) else {
            throw NabError("The link led to \(full.host() ?? "a page") nab doesn't read.")
        }
        if seen.insert(match.entryID).inserted { urls.append(full) }
    } catch {
        expandFailed = true
        complain("\(url.absoluteString): \(error.localizedDescription)")
    }
}

let gate = Gate(limit: 6)
let results = await withTaskGroup(of: (Int, Result<Capture, Error>).self) { group in
    for (index, url) in urls.enumerated() {
        group.addTask {
            guard let provider = registry.match(url)?.provider else {
                return (index, .failure(NabError("Unsupported link")))
            }
            do { return (index, .success(try await gate.run { try await provider.fetch(url) })) } catch {
                return (index, .failure(error))
            }
        }
    }
    var collected: [(Int, Result<Capture, Error>)] = []
    for await result in group { collected.append(result) }
    return collected.sorted { $0.0 < $1.0 }.map(\.1)
}

var captures: [Capture] = []
for (url, result) in zip(urls, results) {
    switch result {
    case .success(let capture): captures.append(capture)
    case .failure(let error): complain("\(url.absoluteString): \(error.localizedDescription)")
    }
}

/// Saves every photo and clip of `capture` into `folder`, all at once (the downloader keeps the count sane).
func save(_ capture: Capture, into folder: URL) async -> (Capture, failed: Bool) {
    guard capture.isMedia, let provider = registry.provider(for: capture.source) else { return (capture, false) }
    let names = MediaFileName.names(for: capture, sourceName: provider.name)
    var saved = capture
    var failed = false
    await withTaskGroup(of: (Int, Result<Media, Error>, kept: Bool).self) { group in
        for (i, media) in capture.media.enumerated() {
            group.addTask {
                let file = folder.appending(path: names[i])
                // A file saved before under this item's name is kept, not downloaded again.
                let kept = MediaProbe.existing(file, size: media.byteCount) != nil
                do {
                    return (i, .success(try await provider.store(media, of: capture, at: file)), kept)
                } catch {
                    return (i, .failure(error), kept)
                }
            }
        }
        for await (i, result, kept) in group {
            switch result {
            case .success(let media):
                saved.media[i] = media
                complain("\(kept ? "already saved" : "saved") \(media.savedPath ?? "")")
            case .failure(let error):
                failed = true
                complain("\(names[i]): \(error.localizedDescription)")
            }
        }
    }
    return (saved, failed)
}

var saveFailed = false
if let saveFolder {
    for i in captures.indices {
        let (saved, failed) = await save(captures[i], into: saveFolder)
        captures[i] = saved
        saveFailed = saveFailed || failed
    }
}

if options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(captures))
    print()
} else if !captures.isEmpty {
    print(ContextPack.render(captures), terminator: "")
}
exit(captures.count == urls.count && !expandFailed && !saveFailed ? 0 : 1)
