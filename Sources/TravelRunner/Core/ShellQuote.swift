import Foundation

/// Builds `zsh -c` command strings from argv arrays. Service commands are argv,
/// not shell snippets, so every argument is quoted: a path such as
/// `…/TRAVEL BOOKING/…` must stay one argument.
enum ShellQuote {
    private static let safe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-"
    )

    static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }
}
