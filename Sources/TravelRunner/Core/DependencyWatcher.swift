import Foundation

actor DependencyWatcher {
    private let repoPaths: [String: String]
    private(set) var staleServices: Set<String> = []

    init(repoPaths: [String: String]) {
        self.repoPaths = repoPaths
    }

    @discardableResult
    func check() -> Set<String> {
        var stale = Set<String>()
        var checked = Set<String>()

        for (serviceID, path) in repoPaths {
            if checked.contains(path) {
                if stale.contains(where: { repoPaths[$0] == path }) {
                    stale.insert(serviceID)
                }
                continue
            }
            checked.insert(path)

            let packageJsonPath = (path as NSString).appendingPathComponent("package.json")
            let lockfilePath = (path as NSString).appendingPathComponent("node_modules/.package-lock.json")

            guard let packageMtime = mtime(at: packageJsonPath) else { continue }
            guard let lockMtime = mtime(at: lockfilePath) else {
                stale.insert(serviceID)
                continue
            }

            if packageMtime > lockMtime {
                stale.insert(serviceID)
            }
        }

        staleServices = stale
        return stale
    }

    private func mtime(at path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}
