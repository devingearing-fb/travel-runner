import Foundation

/// How the hackathon fork starts platform core (`apps/platform-core`, Next.js).
///
/// The fork decides the port and the env file of the app, in a script of the app's
/// `package.json`. The runner reads the two from that script, so that the runner and
/// a `pnpm dev:platform-core` in a terminal start the app in the same way, also after
/// the fork changes the port.
enum PlatformCoreApp {
    /// The script that `pnpm dev:platform-core` at the root of the fork runs, for example
    /// `dotenv -e .env.dev -- next dev --turbopack -p 3007`.
    static let script = "dev:dev"
    static let command = ["pnpm", script]
    /// The port of the script when this version of the runner was made. It applies only
    /// while the runner cannot read the script (no checkout of the app).
    static let defaultPort = 3007
    /// The env file of the script when this version of the runner was made.
    static let defaultEnvFile = ".env.dev"

    /// What a script says about the start of the app.
    struct Launch: Equatable, Sendable {
        /// The port after `-p` or `--port`. Nil when the script names no port.
        var port: Int?
        /// The files after `-e` of dotenv, the strongest first.
        var envFiles: [String]
    }

    static func launch(ofScript text: String) -> Launch {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var launch = Launch(port: nil, envFiles: [])
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            switch word {
            case "-p", "--port":
                if let port = next.flatMap(Int.init) { launch.port = port }
            case "-e":
                if let file = next, !file.hasPrefix("-") { launch.envFiles.append(file) }
            default:
                for prefix in ["--port=", "-p="] where word.hasPrefix(prefix) {
                    if let port = Int(word.dropFirst(prefix.count)) { launch.port = port }
                }
            }
        }
        return launch
    }

    /// The start that the app's `package.json` gives. Nil without the file or without the script.
    static func launch(directory: String) -> Launch? {
        let path = (directory as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: path),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = package["scripts"] as? [String: Any],
              let text = scripts[script] as? String else { return nil }
        return launch(ofScript: text)
    }

    /// The file that Import… writes: the first env file of the script.
    static func envFile(directory: String) -> String {
        launch(directory: directory)?.envFiles.first ?? defaultEnvFile
    }
}

/// The env of platform core.
///
/// The app uses the services that its own env names (the database, the login). Its
/// env is a file that people send to each other. The runner does not write that file,
/// and it gives the app no values of its own.
enum PlatformCoreEnv {
    /// Without these the app stops at its start (`src/env.server.ts`, `src/env.client.ts`).
    static let requiredKeys = ["LOGIN_URL", "NEXT_PUBLIC_FASTBREAK_DOMAIN"]

    /// What the app gets: the files of the script (dotenv puts them into the process,
    /// so they are the strongest), then the files that `next dev` reads in the folder.
    static func values(directory: String, envFiles: [String]) -> [String: String] {
        var values = EventDirectoryEnv.values(directory: directory)
        for name in envFiles.reversed() {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            values.merge(AgentEnv.parse(content, dialect: .node)) { _, stronger in stronger }
        }
        return values
    }

    static func missingKeys(_ values: [String: String]) -> [String] {
        requiredKeys.filter { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Why a file is not the env of platform core, or nil when it is.
    static func importProblem(_ values: [String: String]) -> String? {
        let missing = missingKeys(values)
        return missing.isEmpty ? nil : "It does not set \(missing.joined(separator: " and "))."
    }
}

/// Decides how the runner starts platform core.
enum PlatformCoreLauncher {
    enum Decision: Equatable, Sendable {
        /// Start it; the lines go to the log of the service.
        case run(notes: [String])
        case skip(String)
    }

    /// `launch`: what the app's script says now, nil without the app or the script.
    /// `runnerPort`: the port that the runner read when it loaded its services.
    static func decide(
        launch: PlatformCoreApp.Launch?,
        runnerPort: Int?,
        hasPackages: Bool,
        missingKeys: [String]
    ) -> Decision {
        let folder = RepoDetector.platformCoreDirectory
        guard let launch else {
            return .skip(
                "This checkout does not have \(folder) with the script `\(PlatformCoreApp.script)`. "
                    + "Pull the fork, then restart platform core."
            )
        }
        guard let port = launch.port else {
            return .skip("The script `\(PlatformCoreApp.script)` of \(folder) names no port, so the runner cannot tell where the app listens.")
        }
        guard port == runnerPort else {
            return .skip(
                "The fork now starts platform core on port \(port). The runner read port "
                    + "\(runnerPort.map(String.init) ?? "none") when it started. Quit the runner and open it again."
            )
        }
        guard hasPackages else {
            return .skip("Its packages are not installed. Run pnpm install at the root of the fork, then restart platform core.")
        }
        let envFile = launch.envFiles.first ?? ".env.local"
        guard missingKeys.isEmpty else {
            return .skip(
                "Its env is not there (\(missingKeys.joined(separator: ", "))). Put the env file of platform core at "
                    + "\(folder)/\(envFile), or use Import… on the Environment Check step. Then restart platform core."
            )
        }
        return .run(notes: [
            "Platform core is at http://localhost:\(port), the port of its script `\(PlatformCoreApp.script)`. "
                + "It uses the database and the login that its env names (\(folder)/\(envFile)); the runner gives it no values.",
        ])
    }
}
