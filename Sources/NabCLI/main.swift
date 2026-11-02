import Foundation
import NabCore
import NabSources

// nab <link>... — fetches every link in parallel and prints one context pack to stdout.
// The same core the app uses, so agents can read videos and pins without the UI.

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
var saveFolder: URL?
var input: [String] = []
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if argument == "--save" {
        guard index + 1 < arguments.count else {
            FileHandle.standardError.write(Data("nab: --save needs a folder\n".utf8))
            exit(64)
        }
        let path = (arguments[index + 1] as NSString).expandingTildeInPath
        saveFolder = URL(filePath: path, directoryHint: .isDirectory, relativeTo: .currentDirectory()).absoluteURL
        index += 2
        continue
    }
    if !argument.hasPrefix("--") { input.append(argument) }
    index += 1
}

let registry = SourceRegistry.standard

if input.isEmpty || arguments.contains("--help") {
    print(
        """
        usage: nab [--json] [--save <folder>] <link>...
          Reads \(RackText.list(registry.names)) links in parallel and prints a context pack for AI: a video's
          details and transcript, or an item's details and its photos and clips.
          --json           print captures as JSON instead (photos and clips under "media")
          --save <folder>  save each pin's photos and clips there at full size; the pack lists the saved files
        """)
    exit(input.isEmpty && !arguments.contains("--help") ? 64 : 0)
}

let found = registry.links(in: input.joined(separator: "\n"))
if found.isEmpty {
    FileHandle.standardError.write(Data("nab: no supported links found\n".utf8))
    exit(65)
}
// Share links (pin.it/…) name their item only after one request.
var urls: [URL] = []
var expandFailed = false
for url in found {
    do {
        let full = try await registry.expand(url)
        if registry.match(full) != nil, !urls.contains(full) { urls.append(full) }
    } catch {
        expandFailed = true
        FileHandle.standardError.write(Data("nab: \(url.absoluteString): \(error.localizedDescription)\n".utf8))
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
    case .failure(let error):
        FileHandle.standardError.write(Data("nab: \(url.absoluteString): \(error.localizedDescription)\n".utf8))
    }
}

/// Saves every photo and clip of `capture` into `folder`, all at once (the downloader keeps the count sane).
func save(_ capture: Capture, into folder: URL) async -> (Capture, failed: Bool) {
    guard capture.isMedia, let provider = registry.provider(for: capture.source) else { return (capture, false) }
    let names = MediaFileName.names(for: capture, sourceName: provider.name)
    var saved = capture
    var failed = false
    await withTaskGroup(of: (Int, Result<Media, Error>).self) { group in
        for (i, media) in capture.media.enumerated() {
            group.addTask {
                do {
                    let item = try await provider.store(media, of: capture, at: folder.appending(path: names[i]))
                    return (i, .success(item))
                } catch {
                    return (i, .failure(error))
                }
            }
        }
        for await (i, result) in group {
            switch result {
            case .success(let media):
                saved.media[i] = media
                FileHandle.standardError.write(Data("nab: saved \(media.savedPath ?? "")\n".utf8))
            case .failure(let error):
                failed = true
                FileHandle.standardError.write(Data("nab: \(names[i]): \(error.localizedDescription)\n".utf8))
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

if wantsJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(captures))
    print()
} else if !captures.isEmpty {
    print(ContextPack.render(captures), terminator: "")
}
exit(captures.count == urls.count && !expandFailed && !saveFailed ? 0 : 1)
