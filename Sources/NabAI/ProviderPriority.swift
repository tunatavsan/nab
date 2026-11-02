/// Which provider the chooser preselects once every check has finished.
public enum ProviderPriority {
    /// The provider already in the settings if it is ready; otherwise the first ready one in the order the providers
    /// are listed. Nothing here depends on which check happened to answer first.
    public static func preselected(ready: Set<ProviderKind>, current: ProviderKind) -> ProviderKind? {
        if ready.contains(current) { return current }
        return ProviderKind.allCases.first { ready.contains($0) }
    }
}
