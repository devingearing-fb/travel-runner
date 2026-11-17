import CoreFoundation
import Foundation

enum DbManifestLoader {
    static let supportedSeedScenarioVersions: Set<Int> = [3, 4]

    /// Why the steps of a profile cannot be read from the manifest. Nothing runs then:
    /// a bad manifest never falls back to the built-in steps.
    enum ManifestError: LocalizedError, Equatable {
        case unreadable(String)
        case unknownProfile(String)
        case unknownStep(profile: String, step: String)
        case emptyProfile(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return "Cannot read scripts/db/manifest.json: \(reason). Nothing was run."
            case .unknownProfile(let profile):
                return "Profile '\(profile)' is not defined on this branch"
            case .unknownStep(let profile, let step):
                return "Profile '\(profile)' names step '\(step)', which scripts/db/manifest.json does not define. Nothing was run."
            case .emptyProfile(let profile):
                return "Profile '\(profile)' has no steps in scripts/db/manifest.json. Nothing was run."
            }
        }
    }

    /// The steps of `profile`. Keys the runner does not know are ignored, so a newer
    /// manifest still loads. With no manifest file the built-in steps run
    /// (`DbSetupPipeline.builtInStepsLabel`); any other problem throws.
    @MainActor
    static func load(from manifestPath: String, profile: String) throws -> [DbSetupStep] {
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            return DbSetupPipeline.buildDefault()
        }
        let manifest = try readManifest(manifestPath)
        guard let profileStepIDs = manifest.profiles[profile] else {
            throw ManifestError.unknownProfile(profile)
        }
        guard !profileStepIDs.isEmpty else { throw ManifestError.emptyProfile(profile) }

        // `idleTimeoutMs` of a step, else of the manifest, else 180 s.
        let defaultIdleMs = manifest.idleTimeoutMs ?? DbSetupStep.defaultIdleTimeoutSeconds * 1000

        var result: [DbSetupStep] = []
        for (index, stepID) in profileStepIDs.enumerated() {
            guard let definition = manifest.steps[stepID] else {
                throw ManifestError.unknownStep(profile: profile, step: stepID)
            }
            guard let command = definition["command"] as? String,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ManifestError.unreadable("step '\(stepID)' has no command")
            }
            result.append(DbSetupStep(
                id: stepID,
                name: definition["name"] as? String ?? stepID,
                command: command,
                healthCheckCommand: definition["healthCheck"] as? String,
                timeoutSeconds: ((definition["timeoutMs"] as? Int) ?? 60000) / 1000,
                isOptional: definition["optional"] as? Bool ?? false,
                stepNumber: index + 1,
                idleTimeoutSeconds: max(1, ((definition["idleTimeoutMs"] as? Int) ?? defaultIdleMs) / 1000)
            ))
        }
        return result
    }

    /// The parts of the manifest that name the steps.
    private struct StepManifest {
        let steps: [String: [String: Any]]
        let profiles: [String: [String]]
        let idleTimeoutMs: Int?
    }

    private static func readManifest(_ manifestPath: String) throws -> StepManifest {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        } catch {
            throw ManifestError.unreadable(error.localizedDescription)
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManifestError.unreadable("it is not valid JSON")
        }
        guard let json = raw as? [String: Any] else {
            throw ManifestError.unreadable("the root must be an object")
        }
        guard let stepsArray = json["steps"] as? [[String: Any]] else {
            throw ManifestError.unreadable("steps must be a list of objects")
        }
        guard let profiles = json["profiles"] as? [String: [String]] else {
            throw ManifestError.unreadable("profiles must map each name to a list of step ids")
        }
        var steps: [String: [String: Any]] = [:]
        for step in stepsArray {
            guard let id = step["id"] as? String, !id.isEmpty else {
                throw ManifestError.unreadable("a step has no id")
            }
            steps[id] = step
        }
        return StepManifest(steps: steps, profiles: profiles, idleTimeoutMs: json["idleTimeoutMs"] as? Int)
    }

    /// The profile names of the manifest, or nil when it is absent or unreadable.
    /// A caller that offers a profile asks this first, so the button is hidden when
    /// the branch lacks it.
    static func profileNames(from manifestPath: String) -> Set<String>? {
        profiles(from: manifestPath).map { Set($0.keys) }
    }

    /// Profile name to step ids, or nil when the manifest is absent or unreadable.
    static func profiles(from manifestPath: String) -> [String: [String]]? {
        guard FileManager.default.fileExists(atPath: manifestPath) else { return nil }
        return try? readManifest(manifestPath).profiles
    }

    static func loadSeedScenarios(from manifestPath: String) throws -> DbSeedScenarioCatalog {
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw SeedScenarioError.unreadableManifest(error.localizedDescription)
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SeedScenarioError.malformedMetadata(error.localizedDescription)
        }
        guard let manifest = raw as? [String: Any] else {
            throw SeedScenarioError.malformedMetadata("the manifest root must be an object")
        }

        let repositoryURL = manifestURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard manifest.keys.contains("seedScenarios") else {
            return try loadLegacyScenario(repositoryURL: repositoryURL)
        }
        guard let version = integer(manifest["version"]) else {
            throw SeedScenarioError.malformedMetadata(
                "version must be an integer when seedScenarios is present"
            )
        }
        // Version 4 (the monorepo) changed the steps, not the seed scenario section.
        guard supportedSeedScenarioVersions.contains(version) else {
            throw SeedScenarioError.unsupportedVersion(version)
        }
        // Keys this runner does not know are ignored: a newer checkout can add some.
        guard let section = manifest["seedScenarios"] as? [String: Any],
              let directory = section["directory"] as? String else {
            throw SeedScenarioError.malformedMetadata(
                "seedScenarios must contain a string directory"
            )
        }

        let scenariosDirectory = try validateScenariosDirectory(
            directory,
            repositoryURL: repositoryURL
        )
        return try buildCatalog(from: discoverScenarios(
            in: scenariosDirectory,
            repositoryURL: repositoryURL
        ))
    }

    private struct ScenarioDefinition {
        let id: String
        let name: String
        let description: String
        let order: Int
        let isDefault: Bool
        let baseID: String?
        let variables: [String: String]
        let dynamicVariables: [String: String]
    }

    private struct EffectiveScenario {
        let sqlFileCount: Int
        let variables: [String: String]
    }

    enum SeedScenarioError: LocalizedError, Equatable {
        case unreadableManifest(String)
        case malformedMetadata(String)
        case unsupportedVersion(Int)
        case invalidDirectory(path: String, reason: String)
        case invalidDescriptor(scenario: String, reason: String)
        case duplicateID(String)
        case duplicateOrder(Int)
        case invalidDefaultCount(Int)
        case unknownBase(scenario: String, base: String)
        case inheritanceCycle(String)

        var errorDescription: String? {
            switch self {
            case .unreadableManifest(let reason):
                return "Cannot read the database manifest: \(reason)"
            case .malformedMetadata(let reason):
                return "Seed scenario metadata is malformed: \(reason)"
            case .unsupportedVersion(let version):
                return "Seed scenario folders require manifest version 3 or 4, but found version \(version)."
            case .invalidDirectory(let path, let reason):
                return "Seed scenario directory ‘\(path)’ is invalid: \(reason)."
            case .invalidDescriptor(let scenario, let reason):
                return "Seed scenario ‘\(scenario)’ is invalid: \(reason)."
            case .duplicateID(let id):
                return "Seed scenario ID ‘\(id)’ is duplicated."
            case .duplicateOrder(let order):
                return "Seed scenario order \(order) is duplicated."
            case .invalidDefaultCount(let count):
                return "Seed scenario folders must contain exactly one default scenario; found \(count)."
            case .unknownBase(let scenario, let base):
                return "Seed scenario ‘\(scenario)’ extends unknown scenario ‘\(base)’."
            case .inheritanceCycle(let id):
                return "Seed scenario inheritance contains a cycle involving ‘\(id)’."
            }
        }
    }

    private static func loadLegacyScenario(
        repositoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> DbSeedScenarioCatalog {
        try validateRequiredFile(
            repositoryURL.appendingPathComponent("supabase/seed.sql"),
            displayPath: "supabase/seed.sql",
            scenarioID: "standard",
            repositoryURL: repositoryURL,
            fileManager: fileManager
        )
        let scenario = DbSeedScenario(
            id: "standard",
            name: "Standard",
            description: "Standard development fixtures.",
            fileSummary: "seed.sql",
            variables: []
        )
        return DbSeedScenarioCatalog(defaultID: scenario.id, items: [scenario])
    }

    private static func validateScenariosDirectory(
        _ relativePath: String,
        repositoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isNormalizedRelativePath(relativePath) else {
            throw SeedScenarioError.invalidDirectory(
                path: relativePath,
                reason: "it must be a normalized project-root-relative path"
            )
        }
        guard relativePath.rangeOfCharacter(
            from: CharacterSet(charactersIn: "*?[]{}()!")
        ) == nil else {
            throw SeedScenarioError.invalidDirectory(
                path: relativePath,
                reason: "it must not contain glob syntax"
            )
        }
        try rejectSymlinkComponents(
            relativePath,
            repositoryURL: repositoryURL,
            fileManager: fileManager
        )

        let directoryURL = repositoryURL.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard isContained(directoryURL, by: repositoryURL) else {
            throw SeedScenarioError.invalidDirectory(
                path: relativePath,
                reason: "its real path escapes the repository"
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SeedScenarioError.invalidDirectory(
                path: relativePath,
                reason: "the directory does not exist"
            )
        }
        return directoryURL
    }

    private static func discoverScenarios(
        in directoryURL: URL,
        repositoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> [ScenarioDefinition] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw SeedScenarioError.invalidDirectory(
                path: directoryURL.lastPathComponent,
                reason: "it cannot be listed: \(error.localizedDescription)"
            )
        }

        var definitions: [ScenarioDefinition] = []
        var ids = Set<String>()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw invalidDescriptor(entry.lastPathComponent, "its folder cannot be inspected")
            }
            if values.isSymbolicLink == true {
                throw invalidDescriptor(
                    entry.lastPathComponent,
                    "scenario folders must not be symbolic links"
                )
            }
            guard values.isDirectory == true else { continue }
            let id = entry.lastPathComponent
            guard isValidID(id) else {
                throw invalidDescriptor(id, "the folder name must be lowercase kebab-case")
            }
            guard ids.insert(id).inserted else { throw SeedScenarioError.duplicateID(id) }
            let normalizedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
            guard isContained(normalizedEntry, by: repositoryURL) else {
                throw invalidDescriptor(id, "its real folder path escapes the repository")
            }
            definitions.append(try loadDescriptor(
                scenarioID: id,
                directoryURL: normalizedEntry,
                repositoryURL: repositoryURL,
                fileManager: fileManager
            ))
        }
        guard !definitions.isEmpty else {
            throw SeedScenarioError.malformedMetadata(
                "the seed scenario directory contains no scenario folders"
            )
        }
        return definitions
    }

    private static func loadDescriptor(
        scenarioID: String,
        directoryURL: URL,
        repositoryURL: URL,
        fileManager: FileManager
    ) throws -> ScenarioDefinition {
        let descriptorURL = directoryURL.appendingPathComponent("scenario.json")
        try validateRequiredFile(
            descriptorURL,
            displayPath: "\(scenarioID)/scenario.json",
            scenarioID: scenarioID,
            repositoryURL: repositoryURL,
            fileManager: fileManager
        )
        try validateRequiredFile(
            directoryURL.appendingPathComponent("seed.sql"),
            displayPath: "\(scenarioID)/seed.sql",
            scenarioID: scenarioID,
            repositoryURL: repositoryURL,
            fileManager: fileManager
        )

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL))
        } catch {
            throw invalidDescriptor(
                scenarioID,
                "scenario.json is malformed: \(error.localizedDescription)"
            )
        }
        guard let descriptor = raw as? [String: Any] else {
            throw invalidDescriptor(scenarioID, "scenario.json must contain an object")
        }
        let requiredKeys: Set<String> = [
            "version", "id", "name", "description", "order", "default", "extends", "settings",
        ]
        guard Set(descriptor.keys) == requiredKeys else {
            throw invalidDescriptor(
                scenarioID,
                "scenario.json must contain exactly version, id, name, description, order, default, extends, and settings"
            )
        }
        guard integer(descriptor["version"]) == 1 else {
            throw invalidDescriptor(scenarioID, "descriptor version must be 1")
        }
        guard let id = descriptor["id"] as? String, isValidID(id) else {
            throw invalidDescriptor(scenarioID, "id must be lowercase kebab-case")
        }
        guard id == scenarioID else {
            throw invalidDescriptor(scenarioID, "id ‘\(id)’ must match its folder name")
        }
        guard let name = descriptor["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalidDescriptor(scenarioID, "name must be a non-empty string")
        }
        guard let description = descriptor["description"] as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalidDescriptor(scenarioID, "description must be a non-empty string")
        }
        guard let order = integer(descriptor["order"]), order >= 0 else {
            throw invalidDescriptor(scenarioID, "order must be a nonnegative integer")
        }
        guard let isDefault = boolean(descriptor["default"]) else {
            throw invalidDescriptor(scenarioID, "default must be a boolean")
        }
        let baseID: String?
        if descriptor["extends"] is NSNull {
            baseID = nil
        } else if let value = descriptor["extends"] as? String, isValidID(value) {
            baseID = value
        } else {
            throw invalidDescriptor(
                scenarioID,
                "extends must be null or a lowercase kebab-case scenario ID"
            )
        }
        guard let settings = descriptor["settings"] as? [String: Any] else {
            throw invalidDescriptor(scenarioID, "settings must be an object")
        }
        guard Set(settings.keys).isSubset(of: ["variables", "dynamicVariables"]) else {
            throw invalidDescriptor(
                scenarioID,
                "settings may contain only variables and dynamicVariables"
            )
        }
        let variables = try parseStaticVariables(settings["variables"], scenarioID: scenarioID)
        let dynamicVariables = try parseDynamicVariables(
            settings["dynamicVariables"],
            scenarioID: scenarioID
        )
        if let collision = Set(variables.keys).intersection(dynamicVariables.keys).sorted().first {
            throw invalidDescriptor(
                scenarioID,
                "variable ‘\(collision)’ appears in both variables and dynamicVariables"
            )
        }
        return ScenarioDefinition(
            id: id,
            name: name,
            description: description,
            order: order,
            isDefault: isDefault,
            baseID: baseID,
            variables: variables,
            dynamicVariables: dynamicVariables
        )
    }

    private static func parseStaticVariables(
        _ raw: Any?,
        scenarioID: String
    ) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let object = raw as? [String: Any] else {
            throw invalidDescriptor(scenarioID, "settings.variables must be an object")
        }
        var result: [String: String] = [:]
        for (name, value) in object {
            try validateVariableName(name, scenarioID: scenarioID)
            if let string = value as? String {
                result[name] = quoted(string)
            } else if let bool = boolean(value) {
                result[name] = bool ? "true" : "false"
            } else if let number = value as? NSNumber,
                      !isBoolean(number), number.doubleValue.isFinite {
                result[name] = number.stringValue
            } else {
                throw invalidDescriptor(
                    scenarioID,
                    "static variable ‘\(name)’ must be a string, finite number, or boolean"
                )
            }
        }
        return result
    }

    private static func parseDynamicVariables(
        _ raw: Any?,
        scenarioID: String
    ) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let object = raw as? [String: Any] else {
            throw invalidDescriptor(scenarioID, "settings.dynamicVariables must be an object")
        }
        var result: [String: String] = [:]
        let knownZones = Set(TimeZone.knownTimeZoneIdentifiers)
        for (name, value) in object {
            try validateVariableName(name, scenarioID: scenarioID)
            guard let definition = value as? [String: Any],
                  Set(definition.keys) == ["type", "days", "timeZone"],
                  definition["type"] as? String == "relative-date",
                  let days = integer(definition["days"]),
                  let timeZone = definition["timeZone"] as? String,
                  knownZones.contains(timeZone) else {
                throw invalidDescriptor(
                    scenarioID,
                    "dynamic variable ‘\(name)’ must be a relative-date with integer days and a valid IANA timeZone"
                )
            }
            result[name] = relativeDateSummary(days: days, timeZone: timeZone)
        }
        return result
    }

    private static func buildCatalog(
        from definitions: [ScenarioDefinition]
    ) throws -> DbSeedScenarioCatalog {
        var byID: [String: ScenarioDefinition] = [:]
        var orders = Set<Int>()
        for definition in definitions {
            guard byID.updateValue(definition, forKey: definition.id) == nil else {
                throw SeedScenarioError.duplicateID(definition.id)
            }
            guard orders.insert(definition.order).inserted else {
                throw SeedScenarioError.duplicateOrder(definition.order)
            }
        }
        let defaults = definitions.filter(\.isDefault)
        guard defaults.count == 1 else {
            throw SeedScenarioError.invalidDefaultCount(defaults.count)
        }
        for definition in definitions {
            if let baseID = definition.baseID, byID[baseID] == nil {
                throw SeedScenarioError.unknownBase(scenario: definition.id, base: baseID)
            }
        }

        var effectiveByID: [String: EffectiveScenario] = [:]
        var visiting = Set<String>()
        func resolve(_ id: String) throws -> EffectiveScenario {
            if let effective = effectiveByID[id] { return effective }
            guard visiting.insert(id).inserted else {
                throw SeedScenarioError.inheritanceCycle(id)
            }
            guard let definition = byID[id] else {
                throw SeedScenarioError.unknownBase(scenario: id, base: id)
            }
            var sqlFileCount = 1
            var variables: [String: String] = [:]
            if let baseID = definition.baseID {
                let base = try resolve(baseID)
                sqlFileCount += base.sqlFileCount
                variables = base.variables
            }
            variables.merge(definition.variables) { _, child in child }
            variables.merge(definition.dynamicVariables) { _, child in child }
            visiting.remove(id)
            let effective = EffectiveScenario(sqlFileCount: sqlFileCount, variables: variables)
            effectiveByID[id] = effective
            return effective
        }

        let sorted = definitions.sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
        let items = try sorted.map { definition -> DbSeedScenario in
            let effective = try resolve(definition.id)
            return DbSeedScenario(
                id: definition.id,
                name: definition.name,
                description: definition.description,
                fileSummary: fileSummary(sqlFileCount: effective.sqlFileCount),
                variables: effective.variables.keys.sorted().map {
                    DbSeedScenarioVariable(name: $0, value: effective.variables[$0]!)
                }
            )
        }
        return DbSeedScenarioCatalog(defaultID: defaults[0].id, items: items)
    }

    private static func validateRequiredFile(
        _ fileURL: URL,
        displayPath: String,
        scenarioID: String,
        repositoryURL: URL,
        fileManager: FileManager
    ) throws {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw invalidDescriptor(
                scenarioID,
                "required file ‘\(displayPath)’ does not exist"
            )
        }
        guard values.isSymbolicLink != true else {
            throw invalidDescriptor(
                scenarioID,
                "required file ‘\(displayPath)’ must not be a symbolic link"
            )
        }
        guard isContained(fileURL.resolvingSymlinksInPath().standardizedFileURL, by: repositoryURL)
        else {
            throw invalidDescriptor(
                scenarioID,
                "required file ‘\(displayPath)’ escapes the repository"
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, values.isRegularFile == true else {
            throw invalidDescriptor(
                scenarioID,
                "required file ‘\(displayPath)’ must be a regular file"
            )
        }
    }

    private static func rejectSymlinkComponents(
        _ relativePath: String,
        repositoryURL: URL,
        fileManager: FileManager
    ) throws {
        var candidate = repositoryURL
        for component in relativePath.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw SeedScenarioError.invalidDirectory(
                    path: relativePath,
                    reason: "directory components must not be symbolic links"
                )
            }
        }
    }

    private static func validateVariableName(
        _ name: String,
        scenarioID: String
    ) throws {
        guard name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw invalidDescriptor(
                scenarioID,
                "variable name ‘\(name)’ must start with a lowercase letter and contain only lowercase letters, digits, and underscores"
            )
        }
    }

    private static func invalidDescriptor(
        _ scenarioID: String,
        _ reason: String
    ) -> SeedScenarioError {
        .invalidDescriptor(scenario: scenarioID, reason: reason)
    }

    private static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func isNormalizedRelativePath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let hasWindowsDrivePrefix = path.range(
            of: #"^[A-Za-z]:[\\/]"#,
            options: .regularExpression
        ) != nil
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(path as NSString).isAbsolutePath
            && !hasWindowsDrivePrefix
            && !path.contains("\\")
            && !segments.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }

    private static func isContained(_ candidate: URL, by repositoryURL: URL) -> Bool {
        let root = repositoryURL.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              !isBoolean(number),
              number.compare(NSNumber(value: Int.min)) != .orderedAscending,
              number.compare(NSNumber(value: Int.max)) != .orderedDescending else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        return number.intValue
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    private static func relativeDateSummary(days: Int, timeZone: String) -> String {
        guard days != 0 else { return "today (\(timeZone))" }
        let operation = days > 0 ? "+" : "-"
        let unit = days.magnitude == 1 ? "day" : "days"
        return "today \(operation) \(days.magnitude) \(unit) (\(timeZone))"
    }

    private static func fileSummary(sqlFileCount: Int) -> String {
        let overlayCount = sqlFileCount - 1
        guard overlayCount > 0 else { return "seed.sql" }
        return "seed.sql + \(overlayCount) \(overlayCount == 1 ? "overlay" : "overlays")"
    }
}
