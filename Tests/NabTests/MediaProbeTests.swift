import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import NabCore

@Suite("What a saved file really is")
struct MediaProbeTests {
    func png(width: Int, height: Int, at file: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// A fallback copy saved under the original's name keeps its real size, and its name follows its real type.
    @Test func imagesReportTheirOwnSizeAndType() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let misnamed = folder.appending(path: "Lamp (Pinterest 1).jpg")
        try png(width: 3, height: 2, at: misnamed)
        let facts = try #require(await MediaProbe.facts(of: misnamed, kind: .image))
        #expect(facts.width == 3 && facts.height == 2)
        #expect(MediaProbe.corrected(misnamed, type: facts.type)?.lastPathComponent == "Lamp (Pinterest 1).png")
        #expect(MediaProbe.corrected(folder.appending(path: "a.png"), type: facts.type) == nil)
        #expect(MediaProbe.corrected(folder.appending(path: "a.jpg"), type: .jpeg) == nil)
    }

    /// A source that writes a small picture instead of downloading, and counts how often it was asked.
    final class Painter: SourceProvider, @unchecked Sendable {
        let kind = SourceKind(rawValue: "pins")
        let name = "Pins"
        private let lock = NSLock()
        private var asked = 0
        var saves: Int { lock.withLock { asked } }
        func identify(_ url: URL) -> String? { nil }
        func fetch(_ url: URL) async throws -> Capture { throw NabError("unused") }
        func save(
            _ media: Media, of capture: Capture, to file: URL,
            progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
        ) async throws {
            lock.withLock { asked += 1 }
            try MediaProbeTests().png(width: 4, height: 5, at: file)
        }
    }

    /// Nabbing a pin again (or after deleting it from the library) finds its file by name and keeps it.
    @Test func aFileSavedBeforeIsKeptAndNotFetchedAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let painter = Painter()
        let photo = Media(kind: .image, url: URL(string: "https://i.example/a.png")!)
        let pin = Capture(source: painter.kind, sourceID: "1", url: photo.url, title: "Lamp", media: [photo])
        let first = try await painter.store(photo, of: pin, at: folder.appending(path: "Lamp (Pins 1).png"))
        #expect(painter.saves == 1)
        #expect(first.width == 4 && first.height == 5 && (first.byteCount ?? 0) > 0)
        let again = try await painter.store(photo, of: pin, at: folder.appending(path: "Lamp (Pins 1).png"))
        #expect(painter.saves == 1)
        #expect(again.savedPath == first.savedPath && again.byteCount == first.byteCount)
        // A copy renamed to its real type is still this item's file.
        try FileManager.default.moveItem(
            at: folder.appending(path: "Lamp (Pins 1).png"), to: folder.appending(path: "Lamp (Pins 1).jpg"))
        let renamed = try await painter.store(photo, of: pin, at: folder.appending(path: "Lamp (Pins 1).png"))
        #expect(painter.saves == 1)
        #expect(renamed.savedURL?.lastPathComponent == "Lamp (Pins 1).jpg")
        // An empty file is not a saved one.
        FileManager.default.createFile(atPath: folder.appending(path: "Lamp (Pins 2).png").path, contents: Data())
        _ = try await painter.store(photo, of: pin, at: folder.appending(path: "Lamp (Pins 2).png"))
        #expect(painter.saves == 2)
        // Nor is one at another size than the one it was saved at.
        var resized = photo
        resized.byteCount = (renamed.byteCount ?? 0) + 1
        _ = try await painter.store(resized, of: pin, at: folder.appending(path: "Lamp (Pins 1).png"))
        #expect(painter.saves == 3)
    }

    /// A file cut short or replaced is not the saved copy: Copy and a drag say it is gone, and nabbing again does not
    /// take it as saved before.
    @Test func aFileAtAnotherSizeIsNotTheSavedOne() throws {
        var photo = Media(
            kind: .image, url: URL(string: "https://i.example/a.png")!, savedPath: "/m/a.png", byteCount: 10)
        #expect(photo.isIntact(size: 10))
        #expect(!photo.isIntact(size: 9) && !photo.isIntact(size: 0) && !photo.isIntact(size: nil))
        let pin = Capture(
            source: SourceKind(rawValue: "pins"), sourceID: "1", url: photo.url, title: "Lamp", media: [photo])
        #expect(CopyPayload.missing([pin]) { _ in 9 } == [photo])
        #expect(CopyPayload.missing([pin]) { _ in 10 }.isEmpty)
        photo.byteCount = nil
        #expect(photo.isIntact(size: 1) && !photo.isIntact(size: 0))

        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Lamp (Pins 1).png")
        FileManager.default.createFile(atPath: file.path, contents: Data("four".utf8))
        #expect(MediaProbe.existing(file, size: 4) == file)
        #expect(MediaProbe.existing(file, size: 5) == nil)
        #expect(MediaProbe.existing(file) == file)
    }

    /// An item an older Nab saved without its list of files holds nothing and is read again; a file of a kind a
    /// newer Nab wrote is skipped, and the item still opens.
    @Test func anEmptyItemIsReadAgainAndAnUnknownKindSkipsOnlyThatFile() throws {
        let head = #"{"source":"pinterest","sourceID":"1","url":"https://example.com/pin/1/","title":"Lamp","#
        let hollow = try JSONDecoder().decode(Capture.self, from: Data((head + #""keywords":[],"chapters":[]}"#).utf8))
        #expect(hollow.holdsNothing)
        let mixed = try JSONDecoder().decode(
            Capture.self,
            from: Data(
                (head + #""keywords":[],"chapters":[],"media":[{"kind":"audio","url":"https://i.example/a.m4a"},"#
                    + #"{"kind":"image","url":"https://i.example/a.png"}]}"#).utf8))
        #expect(mixed.media.map(\.kind) == [.image])
        #expect(!mixed.holdsNothing)
        let read = Capture(
            source: .youtube, sourceID: "a", url: URL(string: "https://youtu.be/a")!, title: "A",
            transcript: Transcript(languageCode: "en", languageName: nil, isGenerated: false, segments: []))
        #expect(!read.holdsNothing)
    }

    @Test func onlyNabsOwnHalfFilesAreLeftovers() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-left-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in [
            "A (Pinterest 1).png.partial", "B (YouTube x) 2.mp4.partial", "notes.partial", "C (Pinterest 2).png",
            "D (Elsewhere 3).png.partial",
        ] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data("x".utf8))
        }
        let found = MediaFolder.leftovers(in: folder, sourceNames: ["YouTube", "Pinterest"])
        #expect(found.map(\.lastPathComponent) == ["A (Pinterest 1).png.partial", "B (YouTube x) 2.mp4.partial"])
    }

    @Test func aLonePhotoAlsoGoesAsAPicture() {
        let photo = URL(filePath: "/m/Lamp (Pins 1).png")
        let clip = URL(filePath: "/m/Lamp (Pins 1) 2.mp4")
        #expect(CopyPayload.files([photo]).loneImage == photo)
        #expect(CopyPayload.files([clip]).loneImage == nil)
        #expect(CopyPayload.files([photo, photo]).loneImage == nil)
        #expect(CopyPayload.text("x").loneImage == nil)
    }
}
