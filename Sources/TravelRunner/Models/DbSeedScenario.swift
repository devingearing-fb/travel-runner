import Foundation

struct DbSeedScenarioVariable: Equatable, Sendable {
    let name: String
    let value: String
}

struct DbSeedScenario: Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let fileSummary: String
    let variables: [DbSeedScenarioVariable]
}

struct DbSeedScenarioCatalog: Equatable, Sendable {
    let defaultID: String
    let items: [DbSeedScenario]

    var defaultScenario: DbSeedScenario? {
        items.first { $0.id == defaultID }
    }
}

enum DbSeedScenarioSelection {
    struct StaleSelectionError: LocalizedError, Equatable {
        let id: String

        var errorDescription: String? {
            "Saved seed scenario ‘\(id)’ is not available on this branch. Choose a seed scenario before resetting the database."
        }
    }

    static func resolve(catalog: DbSeedScenarioCatalog, savedID: String?) throws -> String {
        guard let savedID else { return catalog.defaultID }
        guard catalog.items.contains(where: { $0.id == savedID }) else {
            throw StaleSelectionError(id: savedID)
        }
        return savedID
    }
}
