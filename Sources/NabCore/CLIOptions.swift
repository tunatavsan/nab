import Foundation

/// What `nab` was asked to do, read from its arguments.
public struct CLIOptions: Equatable, Sendable {
    public var json = false
    public var help = false
    /// The folder after `--save`, as typed (`~` and relative paths are resolved by the caller).
    public var saveFolder: String?
    /// Everything that is not an option: text the links are read from.
    public var links: [String] = []

    public enum Problem: Error, Equatable, Sendable {
        case missingFolder
        case unknownOption(String)

        public var message: String {
            switch self {
            case .missingFolder: "--save needs a folder"
            case .unknownOption(let option): "unknown option \(option)"
            }
        }
    }

    /// `--save` takes the next argument as its folder, unless that is missing or is itself an option (`--save
    /// --json` would otherwise make a folder named "--json"). Any other argument starting with `-` is an error, so a
    /// typo is not silently ignored.
    public static func parse(_ arguments: [String]) -> Result<CLIOptions, Problem> {
        var options = CLIOptions()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": options.json = true
            case "--help", "-h": options.help = true
            case "--save":
                guard let folder = rest.popFirst(), !folder.hasPrefix("-") else { return .failure(.missingFolder) }
                options.saveFolder = folder
            default:
                if argument.hasPrefix("-") { return .failure(.unknownOption(argument)) }
                options.links.append(argument)
            }
        }
        return .success(options)
    }
}
