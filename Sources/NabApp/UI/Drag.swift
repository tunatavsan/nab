import AppKit
import NabCore
import SwiftUI

extension View {
    /// Makes the view a drag source for one item: photos and clips drag as their files (one per file), an item read
    /// as text drags as its context pack, the same as its Copy. Nothing drags when a saved file has gone missing.
    ///
    /// SwiftUI's `onDrag` carries a single provider, which loses the files of a pin with several clips, so this
    /// starts an AppKit dragging session instead. It does not take the mouse: clicks and buttons keep working.
    func dragSource(_ capture: Capture?) -> some View {
        overlay { if let capture { DragSource(capture: capture) } }
    }
}

private struct DragSource: NSViewRepresentable {
    let capture: Capture

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ view: DragSourceView, context: Context) { view.capture = capture }
}

/// Invisible to the mouse. A local event monitor watches for a press inside the view followed by a drag, and then
/// begins the session from that event.
final class DragSourceView: NSView, NSDraggingSource {
    var capture: Capture?
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
            pressedAt = event.window === window && bounds.contains(point) ? event.locationInWindow : nil
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
        guard let capture, let payload = DragPayload.resolve(capture) else { return }
        let size = NSSize(width: 48, height: 48)
        let frame = NSRect(
            x: origin.x - size.width / 2, y: origin.y - size.height / 2, width: size.width, height: size.height)
        let items: [NSDraggingItem]
        switch payload {
        case .files(let files):
            items = files.map { file in
                let item = NSDraggingItem(pasteboardWriter: file as NSURL)
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
