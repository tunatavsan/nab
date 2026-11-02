import AppKit
import NabCore
import UniformTypeIdentifiers

extension Pasteboard {
    /// Puts a copy on the clipboard the way the next app expects it: text as text; files as one item per file (a
    /// file URL), and a lone photo also as image data in the same item, so Finder gets the file and an image editor
    /// or a chat gets the picture.
    static func write(_ payload: CopyPayload) {
        switch payload {
        case .text(let text): copy(text)
        case .files(let files):
            let board = Pasteboard.board
            board.clearContents()
            let items = files.map { file -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(file.absoluteString, forType: .fileURL)
                return item
            }
            if let file = payload.loneImage, let type = UTType(filenameExtension: file.pathExtension),
                let data = try? Data(contentsOf: file)
            {
                items[0].setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
                if type != .png, type != .tiff, let tiff = NSImage(data: data)?.tiffRepresentation {
                    items[0].setData(tiff, forType: .tiff)
                }
            }
            board.writeObjects(items)
        }
    }
}
