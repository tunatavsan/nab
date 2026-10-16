import Foundation

/// When the welcome pages open on their own, and the menu bar icon styles.
public enum Onboarding {
    /// Bumped when the welcome changes enough that everyone should see it once more.
    public static let currentVersion = 1

    /// The welcome opens by itself only for an empty library that has not seen this version. Someone with
    /// videos already knows their way around; they can still open it from the menu bar's right-click menu.
    public static func opensAutomatically(libraryIsEmpty: Bool, seenVersion: Int) -> Bool {
        libraryIsEmpty && seenVersion < currentVersion
    }
}

/// How the menu bar icon is drawn: the colored mark, or one template color the menu bar tints.
public enum MenuBarIconStyle: String, Sendable, CaseIterable {
    case color
    case mono

    /// The stored value; anything unknown or missing is the colored mark.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .color
    }
}
