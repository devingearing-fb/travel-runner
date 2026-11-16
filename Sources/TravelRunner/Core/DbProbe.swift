import Foundation

/// The result of one query against the local database.
struct DbQueryResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    /// The first line of the error, for a message to the person.
    var failureDetail: String {
        let line = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? "exit code \(exitCode)"
    }
}

/// What the runner knows about the tables of the local database. Only `empty`
/// permits an automatic reset: a query that failed says nothing about the data.
enum DbProbe: Sendable, Equatable {
    case hasTables
    case empty
    case unknown(String)

    /// Reads the answer to a `SELECT count(*)` of the travel tables.
    static func classify(_ result: DbQueryResult) -> DbProbe {
        guard result.exitCode == 0 else { return .unknown(result.failureDetail) }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(text) else {
            return .unknown(text.isEmpty ? "the query gave no answer" : "unexpected answer: \(text.prefix(80))")
        }
        return count > 0 ? .hasTables : .empty
    }

    static func unreadableMessage(_ detail: String) -> String {
        "Could not read the local database (\(detail)). Nothing was changed."
    }
}
