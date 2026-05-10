import Foundation

actor SecretStore {
    private var secrets: [String: String] = [:]
    private var updatedAt: [String: Date] = [:]
    private var observers: [@Sendable (String, String) -> Void] = []

    func set(_ key: String, value: String) {
        secrets[key] = value
        updatedAt[key] = .now
        for observer in observers {
            observer(key, value)
        }
    }

    func get(_ key: String) -> String? {
        secrets[key]
    }

    func getUpdatedAt(_ key: String) -> Date? {
        updatedAt[key]
    }

    func onChange(_ handler: @escaping @Sendable (String, String) -> Void) {
        observers.append(handler)
    }
}
