/// Which provider the chooser preselects once every check has finished.
public enum ProviderPriority {
    /// The one order of providers: the chooser lists them so, and the preselection takes the first ready one.
    public static let order: [ProviderKind] = ProviderKind.common + ProviderKind.more

    /// The provider already in the settings if it is ready; otherwise the first ready one in the order the providers
    /// are listed. Nothing here depends on which check happened to answer first.
    public static func preselected(ready: Set<ProviderKind>, current: ProviderKind) -> ProviderKind? {
        if ready.contains(current) { return current }
        return order.first { ready.contains($0) }
    }
}
