import AppKit
import NabCore
import SwiftUI

/// Shows what the shortcut just did, under the menu bar icon, without taking focus. The window
/// drops in and lifts out with the same Core Animation spring as the panel; the content inside
/// updates in place as fetches land.
@MainActor
final class ToastController {
    static let size = NSSize(width: 360, height: 76)
    private let panel: FloatingPanel
    private let center: CaptureCenter
    private let anchor: () -> NSRect?

    init(center: CaptureCenter, anchor: @escaping () -> NSRect?) {
        self.center = center
        self.anchor = anchor
        panel = FloatingPanel(size: Self.size, level: .statusBar) { ToastView(center: center) }
        observe { [weak self] in self?.sync() }
    }

    private func sync() {
        if center.toast != nil {
            if !panel.isVisible { panel.place(below: anchor()) }
            panel.present()
        } else {
            panel.dismiss()
        }
    }
}

private struct ToastView: View {
    let center: CaptureCenter

    var body: some View {
        ZStack {
            if let toast = center.toast {
                ToastCard(toast: toast, inFlight: center.inFlight)
                    .onTapGesture { center.dismissToast() }
            }
        }
        .padding(Space.s)
        .frame(width: ToastController.size.width, height: ToastController.size.height)
    }
}

private struct ToastCard: View {
    let toast: CaptureCenter.Toast
    let inFlight: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Palette.well
                if let thumbnail = toast.thumbnail {
                    AsyncImage(url: thumbnail) {
                        $0.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                } else {
                    Image(systemName: "viewfinder").font(Typeface.iconLead).foregroundStyle(Palette.inkSecondary)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(.rect(cornerRadius: Radius.thumb, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if !toast.detail.isEmpty {
                    Text(toast.detail)
                        .font(Typeface.meta)
                        .foregroundStyle(toast.tone == .failed ? Palette.error : Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
            .contentTransition(.opacity)
            Spacer(minLength: Space.xs)
            if inFlight > 1 {
                Text("\(inFlight)")
                    .font(Typeface.mono)
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Palette.accentWash, in: .capsule)
                    .transition(.scale.combined(with: .opacity))
            }
            mark.frame(width: 18, height: 18)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cell()
        .frameProbe("toast.update", Double(toast.pulse))
        .animation(Motion.snap, value: toast)
        .animation(Motion.snap, value: inFlight)
    }

    @ViewBuilder private var mark: some View {
        switch toast.tone {
        case .working:
            ProgressView().controlSize(.small).transition(.scale(scale: 0.5).combined(with: .opacity))
        case .done:
            Image(systemName: "checkmark.circle.fill").font(Typeface.iconMark).foregroundStyle(
                Palette.ok
            )
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(Typeface.iconMark).foregroundStyle(
                Palette.error
            )
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}
