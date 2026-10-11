import NabCore

public enum ChatContext {
    /// The videos as the model sees them: the same pack the user copies, minus earlier summaries
    /// (the conversation already carries them).
    public static func pack(_ captures: [Capture]) -> String {
        ContextPack.render(
            captures.map {
                var capture = $0
                capture.aiSummary = nil
                capture.aiModel = nil
                return capture
            })
    }
}
