import SwiftUI

/// A settings section: a small label above, groups of rows, an optional footnote below.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(Typeface.label).foregroundStyle(Palette.inkTertiary)
                .padding(.leading, Space.l)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.m) { content }
            if let footnote {
                Text(footnote).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                    .padding(.horizontal, Space.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One rounded container of rows, with hairlines between them and none after the last.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            // Rows keep their own identity, so a row appearing above a field (the model ID above the key) does not
            // rebuild the field and drop its focus while someone types.
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, Space.l)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity)
        .raisedCard(radius: Radius.cell)
        .clipShape(.rect(cornerRadius: Radius.cell, style: .continuous))
    }
}

/// A title with an optional line under it.
struct SettingsRowText<Detail: View>: View {
    let title: String
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(Typeface.body).foregroundStyle(Palette.ink)
            detail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRowText where Detail == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// The secondary line of a row.
struct SettingsDetail: View {
    let text: String
    var isError = false

    var body: some View {
        // An empty line would still take a line's height and push the title above the control's center.
        if !text.isEmpty {
            Text(text).font(Typeface.meta).foregroundStyle(isError ? Palette.error : Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A label with an optional line under it, and a control on the right.
struct SettingsRow<Detail: View, Control: View>: View {
    let title: String
    var hasDetail = false
    @ViewBuilder let detail: Detail
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: Space.m) {
            SettingsRowText(title: title) { detail }
            control
        }
        .settingsRowFrame(tall: hasDetail)
    }
}

extension SettingsRow where Detail == SettingsDetail {
    init(
        title: String, detail: String? = nil, detailIsError: Bool = false, @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.hasDetail = detail != nil
        self.detail = SettingsDetail(text: detail ?? "", isError: detailIsError)
        self.control = control()
    }
}

/// A row whose whole width toggles.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    var detailIsError = false
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowText(title: title) {
                if let detail { SettingsDetail(text: detail, isError: detailIsError) }
            }
        }
        .toggleStyle(NabToggleStyle())
        .settingsRowFrame(tall: detail != nil)
    }
}

extension View {
    /// The row box: 44 pt tall, 52 with a second line, `Space.l` across.
    func settingsRowFrame(tall: Bool = false) -> some View {
        padding(.horizontal, Space.l)
            .padding(.vertical, 9)
            .frame(minHeight: tall ? 52 : 44)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An editable field on a row.
    /// Pass the field's own focus binding when the caller reads it; otherwise the field tracks its own.
    func settingsField(focus: FocusState<Bool>.Binding? = nil) -> some View {
        modifier(SettingsFieldStyle(external: focus))
    }
}

/// A hover and press fill for rows that are buttons.
struct SettingsRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.pressed : hovering ? Palette.hover : .clear)
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// The field chrome; the border turns lime while the field has focus.
private struct SettingsFieldStyle: ViewModifier {
    var external: FocusState<Bool>.Binding?
    @FocusState private var own: Bool
    private var focused: Bool { external?.wrappedValue ?? own }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused(external ?? $own)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Palette.field, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(focused ? Palette.accent : Palette.line, lineWidth: focused ? 1.5 : 1)
            )
    }
}
