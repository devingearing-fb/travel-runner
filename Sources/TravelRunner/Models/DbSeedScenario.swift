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
    /// The scenario of the next reset, and the saved one that this branch lacks.
    struct Resolution: Equatable {
        let id: String
        /// The saved scenario that is not on this branch. The reset uses the default
        /// scenario, and the saved choice comes back on a branch that has it.
        let staleID: String?
    }

    /// The saved scenario when this branch has it, else the default one.
    static func resolve(catalog: DbSeedScenarioCatalog, savedID: String?) -> Resolution {
        guard let savedID else { return Resolution(id: catalog.defaultID, staleID: nil) }
        guard catalog.items.contains(where: { $0.id == savedID }) else {
            return Resolution(id: catalog.defaultID, staleID: savedID)
        }
        return Resolution(id: savedID, staleID: nil)
    }

    /// The note when the saved scenario is not on this branch.
    static func staleNotice(id: String, using name: String) -> String {
        "Scenario '\(id)' is not on this branch — using \(name)"
    }
}
