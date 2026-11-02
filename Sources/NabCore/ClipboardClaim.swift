/// Whose copy is on the clipboard, told by the pasteboard's change count. An item that lands copies itself only when
/// nothing was copied since its nab, or when the last copy was Nab's own automatic copy of an item that landed before
/// (so nabbing several items in a row leaves the latest one on the clipboard). A copy the user asked for, in Nab or
/// anywhere else, is never written over.
public struct ClipboardClaim: Sendable {
    /// The change count right after Nab's last automatic copy.
    private var automatic: Int?

    public init() {}

    /// Whether an item nabbed when the count was `mark` may copy itself now that it is `current`.
    public func mayAutoCopy(mark: Int, current: Int) -> Bool { current == mark || current == automatic }

    /// Records a copy by Nab, `count` being the change count right after it: an automatic one may be replaced by the
    /// next item that lands, one the user asked for may not.
    public mutating func copied(at count: Int, automatic: Bool) { self.automatic = automatic ? count : nil }
}
