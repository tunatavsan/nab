import AppKit
import NabCore
import SwiftUI

extension View {
    /// Makes the view a drag source for one item: photos and clips drag as their files (one per file), an item read
    /// as text drags as its context pack, the same as its Copy (a lone photo also as picture data). When a saved file has gone missing
    /// nothing drags and `onMissing` is told, so the page can say "File moved or deleted".
    ///
    /// SwiftUI's `onDrag` carries a single provider, which loses the files of a pin with several clips, so this
    /// starts an AppKit dragging session instead. It does not take the mouse: clicks and buttons keep working.
    func dragSource(_ entry: Entry?, onMissing: @escaping ([Entry]) -> Void) -> some View {
        overlay { if let entry, entry.capture != nil { DragSource(entry: entry, onMissing: onMissing) } }
    }
}

private struct DragSource: NSViewRepresentable {
    let entry: Entry
    let onMissing: ([Entry]) -> Void

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ view: DragSourceView, context: Context) {
        view.entry = entry
        view.onMissing = onMissing
    }
}

/// Invisible to the mouse. A local event monitor watches for a press inside the view followed by a drag, and then
/// begins the session from that event.
final class DragSourceView: NSView, NSDraggingSource {
    var entry: Entry?
    var onMissing: ([Entry]) -> Void = { _ in }
    private var monitor: Any?
    private var pressedAt: NSPoint?
    private var began = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.watch(event) }
            return event
        }
    }

    private func watch(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            began = false
            let point = convert(event.locationInWindow, from: nil)
            // Only the part of the view that shows counts: a card scrolled half out of its list is not a source
            // where it is hidden.
            pressedAt = event.window === window && visibleRect.contains(point) ? event.locationInWindow : nil
        case .leftMouseDragged:
            guard let start = pressedAt, !began else { return }
            let here = event.locationInWindow
            guard hypot(here.x - start.x, here.y - start.y) > 4 else { return }
            began = true
            begin(with: event, from: convert(start, from: nil))
        default:
            pressedAt = nil
        }
    }

    private func begin(with event: NSEvent, from origin: NSPoint) {
        guard let entry, let capture = entry.capture else { return }
        guard let payload = DragPayload.resolve(capture) else {
            onMissing([entry])
            return
        }
        let size = NSSize(width: 48, height: 48)
        let frame = NSRect(
            x: origin.x - size.width / 2, y: origin.y - size.height / 2, width: size.width, height: size.height)
        let items: [NSDraggingItem]
        switch payload {
        case .files(let files):
            items = zip(Pasteboard.fileItems(payload), files).map { writer, file in
                let item = NSDraggingItem(pasteboardWriter: writer)
                item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: file.path))
                return item
            }
        case .text(let text):
            let item = NSDraggingItem(pasteboardWriter: text as NSString)
            item.setDraggingFrame(
                frame, contents: NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil))
            items = [item]
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    { .copy }
}
