import Foundation

enum DbManifestLoader {
    @MainActor
    static func load(from manifestPath: String, profile: String) -> [DbSetupStep] {
        guard let data = FileManager.default.contents(atPath: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stepsArray = json["steps"] as? [[String: Any]],
              let profiles = json["profiles"] as? [String: [String]] else {
            return DbSetupPipeline.buildDefault()
        }

        let profileStepIDs = profiles[profile]
            ?? profiles["reset"]
            ?? stepsArray.map { $0["id"] as? String ?? "" }

        var stepMap: [String: [String: Any]] = [:]
        for step in stepsArray {
            if let id = step["id"] as? String { stepMap[id] = step }
        }

        var result: [DbSetupStep] = []
        for (index, stepID) in profileStepIDs.enumerated() {
            guard let def = stepMap[stepID] else { continue }
            let step = DbSetupStep(
                id: stepID,
                name: def["name"] as? String ?? stepID,
                command: def["command"] as? String ?? "",
                healthCheckCommand: def["healthCheck"] as? String,
                timeoutSeconds: ((def["timeoutMs"] as? Int) ?? 60000) / 1000,
                isOptional: def["optional"] as? Bool ?? false,
                stepNumber: index + 1
            )
            result.append(step)
        }

        return result.isEmpty ? DbSetupPipeline.buildDefault() : result
    }
}
