import Foundation

/// The result of one query against the local database.
struct DbQueryResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    /// The last line of the error, for a message to the person. Docker and psql put
    /// the error last; a line that the login profile prints comes before it.
    var failureDetail: String {
        Self.lastLine(of: stderr) ?? "exit code \(exitCode)"
    }

    /// The last line of `text` that is not empty.
    static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
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
        // The query runs in a login shell, and a profile can print before it. The
        // count is the last line.
        guard let answer = DbQueryResult.lastLine(of: result.stdout) else {
            return .unknown("the query gave no answer")
        }
        guard let count = Int(answer) else { return .unknown("unexpected answer: \(answer.prefix(80))") }
        return count > 0 ? .hasTables : .empty
    }

    static func unreadableMessage(_ detail: String) -> String {
        "Could not read the local database (\(detail)). Nothing was changed."
    }
}
