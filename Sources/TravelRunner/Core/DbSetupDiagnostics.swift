import Foundation

/// What a failed DB step means, and what to do next.
///
/// One table of rules: a rule names its steps (or none, for every step), an exit
/// code, and the text the output must contain. The first rule that matches gives
/// the message, the guidance and the action. Every failure gets guidance.
///
/// The `##db:status:failed:` line of a script is the line the user reads, so it
/// stays the message; the table then adds only the guidance and the action.
enum DbSetupDiagnostics {
    struct Diagnosis: Equatable, Sendable {
        let message: String
        let guidance: String
        let action: RecoveryAction?
    }

    /// What a rule reads.
    struct Failure: Sendable {
        let stepID: String
        let output: [String]
        let exitCode: Int32
        /// The step output and the script's own message, lowercased.
        let text: String
        /// The output of the last migration that ran, lowercased: from the last
        /// "Applying migration" line up to the seed. Nil when no migration ran or the
        /// migrations finished. A failed migration prints its error here.
        var migrationText: String? = nil

        /// The first line that contains `needle` (case does not matter).
        func line(containing needle: String) -> String? {
            output.first { $0.lowercased().contains(needle) }
        }
    }

    struct Rule: Sendable {
        /// The steps the rule is for. Nil: every step.
        let steps: Set<String>?
        /// The exit code the rule is for. Nil: any code.
        let exitCode: Int32?
        /// The output must contain each of these (lowercase).
        let all: [String]
        /// The output must contain one of these (lowercase). Empty: no condition.
        let any: [String]
        /// The output of the last migration must contain each of these (lowercase).
        /// Empty: no condition. Not empty: a run with no failed migration never matches.
        let migration: [String]
        let diagnose: @Sendable (Failure) -> Diagnosis

        init(
            steps: Set<String>? = nil, exitCode: Int32? = nil, all: [String] = [], any: [String] = [],
            migration: [String] = [], diagnose: @escaping @Sendable (Failure) -> Diagnosis
        ) {
            self.steps = steps
            self.exitCode = exitCode
            self.all = all
            self.any = any
            self.migration = migration
            self.diagnose = diagnose
        }

        func matches(_ failure: Failure) -> Bool {
            if let steps, !steps.contains(failure.stepID) { return false }
            if let exitCode, exitCode != failure.exitCode { return false }
            guard all.allSatisfy(failure.text.contains) else { return false }
            if !migration.isEmpty {
                guard let text = failure.migrationText, migration.allSatisfy(text.contains) else { return false }
            }
            return any.isEmpty || any.contains(where: failure.text.contains)
        }
    }

    /// The steps that read or load the hotel dump. Their exit codes 10 to 14 name the
    /// cause (`scripts/db/README.md`, "Exit codes").
    static let hotelSteps: Set<String> = ["check-prerequisites", "fetch-hotels", "load-hotels"]
    /// The steps that talk to the local database.
    static let localDatabaseSteps: Set<String> = [
        "start-supabase", "reset-database", "apply-migrations", "load-hotels", "verify-data",
    ]

    static let retryGuidance = "Read the log below, or copy the error and log to share them. Then retry the step."

    /// The rules, in order. Exit codes first, then the rules of one step, then the
    /// rules for every step, then the catch-all for a failed migration.
    static let rules: [Rule] = [
        // The hotel source (exit codes of fetch-hotels, check-prerequisites, load-hotels).
        Rule(steps: hotelSteps, exitCode: 10) { _ in
            Diagnosis(
                message: "No dev credentials: apps/booking-portal/.env is missing AMATEUR_SUPABASE_URL / ANON_KEY / SIGNING_KEY",
                guidance: "Import the shared .env, then retry the step.",
                action: .importSharedEnv
            )
        },
        Rule(steps: hotelSteps, exitCode: 11) { _ in
            Diagnosis(
                message: "Dev Supabase rejected the signing key (HTTP 401) — your shared .env is out of date",
                guidance: "Import a current shared .env, then retry the step.",
                action: .importSharedEnv
            )
        },
        Rule(steps: hotelSteps, exitCode: 12) { _ in
            Diagnosis(
                message: "Cannot reach dev Supabase — check network or VPN",
                guidance: "Check the network or VPN, then retry the step.",
                action: .retryFromStep
            )
        },
        Rule(steps: hotelSteps, exitCode: 13) { _ in
            Diagnosis(
                message: "Hotel download incomplete — nothing was cached",
                guidance: "Download the hotels again. If it stops again, check the network.",
                action: .redownloadHotels
            )
        },
        Rule(steps: ["load-hotels"], exitCode: 14) { _ in
            Diagnosis(
                message: "The local database is not reachable, or has no hotel table",
                guidance: "Start Supabase and reset the database (Run All of a full setup, or Reset Database), then load the hotels again.",
                action: .retryFromStep
            )
        },

        // One step.
        Rule(steps: ["reset-database"], migration: ["violates foreign key"]) { failure in
            Diagnosis(
                message: "Migration \(migrationFile(failure)): FK constraint violation",
                guidance: "Pull the latest monorepo and fb-amateur-backend, then retry.",
                action: .retryFromStep
            )
        },
        Rule(steps: ["reset-database"], migration: ["already exists"]) { failure in
            Diagnosis(
                message: "Migration \(migrationFile(failure)): object already exists",
                guidance: "A migration creates an object that an earlier one already made. Pull the latest monorepo and fb-amateur-backend, then retry. If it fails again, run pnpm db:stop -- --no-backup at the monorepo root (it deletes the local data), then run all steps.",
                action: .retryFromStep
            )
        },
        Rule(steps: ["start-supabase"], all: ["port", "already in use"]) { _ in
            Diagnosis(
                message: "Port already in use",
                guidance: "Another Supabase instance may be running. Stop it (old checkouts: npx supabase stop; monorepo: pnpm db:stop), then retry the step.",
                action: .retryFromStep
            )
        },
        Rule(steps: ["load-hotels"], all: ["no such file"]) { _ in
            Diagnosis(
                message: "Hotel dump file not found",
                guidance: "Download the hotels again, then load them.",
                action: .redownloadHotels
            )
        },
        Rule(steps: ["copy-event-data"], any: ["urlerror", "connection refused"]) { _ in
            Diagnosis(
                message: "Cannot reach remote Supabase API",
                guidance: "Check the network or VPN, then retry the step.",
                action: .retryFromStep
            )
        },
        Rule(steps: ["copy-event-data"], any: ["401", "403"]) { _ in
            Diagnosis(
                message: "Authentication failed",
                guidance: "Import a current shared .env: the event copy reads its dev keys.",
                action: .importSharedEnv
            )
        },

        // Every step.
        Rule(any: ["cannot connect to the docker daemon", "is the docker daemon running"]) { _ in
            Diagnosis(
                message: "Docker is not running",
                guidance: "Start Docker (or OrbStack), wait until it is ready, then retry the step.",
                action: .openContainerRuntime
            )
        },
        Rule(any: ["cannot find module", "err_module_not_found", "cannot find package"]) { failure in
            let line = failure.line(containing: "cannot find") ?? failure.line(containing: "err_module_not_found")
            return Diagnosis(
                message: line.map { "A Node module is missing: \(trimmed($0))" } ?? "A Node module is missing",
                guidance: "Run pnpm install at the monorepo root, then retry the step.",
                action: .installDependencies
            )
        },
        Rule(any: ["command not found"]) { failure in
            let line = failure.line(containing: "command not found")
            return Diagnosis(
                message: line.map { trimmed($0) } ?? "A command was not found",
                guidance: "Install the tool, or check that a login shell finds it on its PATH, then retry the step.",
                action: .retryFromStep
            )
        },
        Rule(steps: localDatabaseSteps, any: ["could not connect", "connection refused"]) { _ in
            Diagnosis(
                message: "Database connection refused",
                guidance: "The local database is not running. Retry from Start Supabase.",
                action: .retryFromStep
            )
        },

        // A migration that failed for a cause no rule above knows.
        Rule(steps: ["reset-database"], migration: ["error"]) { failure in
            Diagnosis(
                message: "Migration \(migrationFile(failure)) failed",
                guidance: "Check the migration file for errors (supabase/migrations or the backend baseline).",
                action: .retryFromStep
            )
        },
    ]

    /// The diagnosis of a step that exited with `exitCode`. `scriptMessage` is the
    /// error the step reported itself (`status:failed` or `health:fail`), if any.
    static func diagnose(stepID: String, output: [String], exitCode: Int32, scriptMessage: String?) -> Diagnosis {
        let script = scriptMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptText = (script?.isEmpty == false) ? script : nil
        let text = (output + [scriptText ?? ""]).joined(separator: "\n").lowercased()
        let failure = Failure(
            stepID: stepID, output: output, exitCode: exitCode, text: text,
            migrationText: migrationText(output, scriptMessage: scriptText)
        )

        if let rule = rules.first(where: { $0.matches(failure) }) {
            let found = rule.diagnose(failure)
            return Diagnosis(message: scriptText ?? found.message, guidance: found.guidance, action: found.action)
        }
        if let scriptText {
            return Diagnosis(message: scriptText, guidance: retryGuidance, action: .retryFromStep)
        }
        let message = lastMeaningfulLine(output).map { "Exit code \(exitCode): \(trimmed($0))" }
            ?? "Exit code \(exitCode), with no output"
        return Diagnosis(message: message, guidance: retryGuidance, action: .retryFromStep)
    }

    // MARK: - The fallback line

    /// The last line that says something: not empty, not the Node version banner
    /// ("Node.js v20.11.0"), not a stack frame ("    at …"), not a caret or a bracket.
    static func lastMeaningfulLine(_ output: [String]) -> String? {
        output.last { !isNoise($0) }
    }

    static func isNoise(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }
        if text.range(of: #"^Node\.js v\d+"#, options: .regularExpression) != nil { return true }
        if text.hasPrefix("at ") || text == "Thrown at:" { return true }
        if text.hasPrefix("node:internal/") { return true }
        // A caret under the source line, or the end of an error object.
        if text.range(of: #"^[\^~{}\[\]()]+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// A line of the output, cut to the length that a step row can show.
    static func trimmed(_ line: String) -> String {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count > maxLineLength ? String(text.prefix(maxLineLength)) + "…" : text
    }

    static let maxLineLength = 300

    // MARK: - Migrations

    /// The output of the last migration, lowercased, with the script's message when
    /// the output ends in it. Nil when no migration ran, or when a seed line follows
    /// it: the migrations then finished, and the error is not theirs.
    static func migrationText(_ output: [String], scriptMessage: String?) -> String? {
        guard let start = output.lastIndex(where: { $0.contains("Applying migration") }) else { return nil }
        let rest = output[start...].dropFirst()
        if rest.contains(where: isAfterMigrations) { return nil }
        return ([output[start]] + rest + [scriptMessage ?? ""]).joined(separator: "\n").lowercased()
    }

    /// A line that comes only after every migration applied: the CLI's seed and
    /// finish lines, or a psql line of the scenario seed.
    static func isAfterMigrations(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).lowercased()
        return text.hasPrefix("seeding ") || text.hasPrefix("finished supabase db reset") || text.hasPrefix("psql:")
    }

    /// The file of the last "Applying migration" line: the CLI prints each file
    /// before it applies it, so the last one is the one that failed.
    private static func migrationFile(_ failure: Failure) -> String {
        let line = failure.output.last { $0.contains("Applying migration") }
        // "Applying migration 20260101000000_blocks.sql..." names the file.
        guard let line, let range = line.range(of: #"[\w.-]+?\.sql"#, options: .regularExpression) else {
            return "unknown"
        }
        return String(line[range])
    }

    // MARK: - Copy error + log

    /// The text of "Copy error + log": the step, its error, what to do, and its whole
    /// log. The caller redacts it before it leaves the app.
    static func report(
        stepName: String, stepID: String, status: String, exitCode: Int32?,
        error: String?, guidance: String?, log: [String]
    ) -> String {
        var lines = ["DB step: \(stepName) (\(stepID))", "Status: \(status)"]
        if let exitCode { lines.append("Exit code: \(exitCode)") }
        if let error { lines.append("Error: \(error)") }
        if let guidance { lines.append("What to do: \(guidance)") }
        lines.append("")
        lines.append(log.isEmpty ? "Log: (empty)" : "Log:")
        lines += log
        return lines.joined(separator: "\n")
    }

    // MARK: - Elapsed time

    /// "1m 05s / 15m": the time of a step against its hard cap.
    static func elapsedLabel(seconds: Int, capSeconds: Int) -> String {
        "\(duration(seconds)) / \(duration(capSeconds, short: true))"
    }

    static func duration(_ seconds: Int, short: Bool = false) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes == 0 { return "\(rest)s" }
        if short && rest == 0 { return "\(minutes)m" }
        return "\(minutes)m \(String(format: "%02d", rest))s"
    }
}
