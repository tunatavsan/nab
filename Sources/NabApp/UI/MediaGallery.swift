import AVKit
import AppKit
import NabCore
import SwiftUI

/// The body of a record made of photos and clips: every item in order, one under the other. Photos are fitted whole;
/// a clip plays from its file on this Mac. Used by the record page and the transcript drawer alike.
struct MediaGallery: View {
    let entry: Entry
    let center: CaptureCenter
    var inset: CGFloat = 32

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Space.m) {
                ForEach(Array((entry.capture?.media ?? []).enumerated()), id: \.offset) { index, item in
                    MediaTile(
                        item: item, progress: center.savingProgress[entry.id],
                        saveAgain: { center.retry(entry.id) }
                    )
                    .id(index)
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, inset)
            .padding(.vertical, Space.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

/// One photo or clip: its file, or a stand-in while it is being saved or after it went missing.
private struct MediaTile: View {
    let item: Media
    let progress: Double?
    let saveAgain: () -> Void

    private enum Loaded {
        case waiting
        case image(NSImage)
        case clip(AVPlayer)
        case missing
    }

    @State private var loaded = Loaded.waiting

    private var ratio: CGFloat {
        if case .image(let image) = loaded, image.size.height > 0 { return image.size.width / image.size.height }
        if let width = item.width, let height = item.height, width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 16 / 9
    }

    var body: some View {
        Group {
            switch loaded {
            case .waiting:
                Palette.well.overlay {
                    if item.savedPath == nil {
                        VStack(spacing: Space.s) {
                            ProgressView(value: progress).controlSize(.small).frame(maxWidth: 160)
                            if let progress {
                                Text("Saving… \(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%")
                                    .font(Typeface.meta)
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                        }
                    }
                }
            case .image(let image):
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityLabel(RackText.mediaLine(item))
            case .clip(let player):
                ClipPlayer(player: player)
            case .missing:
                Palette.well.overlay { MissingNote(onSaveAgain: saveAgain).padding(Space.m) }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: Radius.thumb, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).strokeBorder(Palette.line))
        .task(id: item.savedPath) { await load() }
        .onDisappear {
            if case .clip(let player) = loaded { player.pause() }
        }
    }

    private func load() async {
        guard let file = item.savedURL else {
            loaded = .waiting
            return
        }
        // The same test as Copy: a file moved, deleted or cut short is missing.
        let item = item
        let intact = await Task.detached { item.isIntact(size: MediaProbe.fileSize(atPath: file.path)) }.value
        guard intact else {
            loaded = .missing
            return
        }
        switch item.kind {
        case .video:
            loaded = .clip(AVPlayer(url: file))
        case .image:
            let image = await Task.detached { NSImage(contentsOf: file) }.value
            loaded = image.map { .image($0) } ?? .missing
        }
    }
}

/// "File moved or deleted · Save again": shown where a file is wanted and gone.
struct MissingNote: View {
    let onSaveAgain: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Text("File moved or deleted ·").font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
            NabButton("Save again", kind: .ghost, action: onSaveAgain)
        }
        .accessibilityElement(children: .contain)
    }
}

/// AVKit's player view with its own controls. SwiftUI's `VideoPlayer` stands on AVKit without linking it into this
/// build, so the app would stop the moment a clip is drawn; naming `AVPlayerView` links it.
private struct ClipPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
