import Foundation

/// Readable model names for chips and chat footers.
public enum ModelNames {
    /// `claude-sonnet-5-5` → "Sonnet 5.5"; ids that are not Claude's come back as they are.
    public static func display(_ id: String) -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("claude-") else { return id }
        var words: [String] = []
        var numbers: [String] = []
        for part in id.dropFirst("claude-".count).split(separator: "-") {
            if part.allSatisfy(\.isNumber) {
                // A trailing date (20250514) is not a version.
                if part.count < 8 { numbers.append(String(part)) }
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        guard !words.isEmpty else { return id }
        return (words + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")])).joined(separator: " ")
    }

    /// The models the picker offers for a provider; empty when the provider cannot list its own.
    public static func choices(for kind: ProviderKind) -> [String] {
        kind == .claudeCLI || kind == .anthropic ? ClaudeModels.current : kind.suggestedModels
    }
}
