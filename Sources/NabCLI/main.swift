import Foundation
import NabCore
import NabYouTube

// nab <link>... — fetches every link in parallel and prints one AI-ready context pack to stdout.
// The same core the app uses, so agents can read videos without the UI.

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
let input = arguments.filter { !$0.hasPrefix("--") }

if input.isEmpty || arguments.contains("--help") {
    print(
        """
        usage: nab [--json] <link>...
          Fetches each link's details and transcript in parallel and prints an AI-ready context pack.
          --json   print captures as JSON instead
        """)
    exit(input.isEmpty && !arguments.contains("--help") ? 64 : 0)
}

let registry = SourceRegistry([YouTubeSource()])
let urls = registry.links(in: input.joined(separator: "\n"))
if urls.isEmpty {
    FileHandle.standardError.write(Data("nab: no supported links found\n".utf8))
    exit(65)
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

if wantsJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(captures))
    print()
} else if !captures.isEmpty {
    print(ContextPack.render(captures), terminator: "")
}
exit(captures.count == urls.count ? 0 : 1)
