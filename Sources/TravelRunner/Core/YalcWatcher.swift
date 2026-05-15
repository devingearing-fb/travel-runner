import Foundation

actor YalcWatcher {
    private let srcDir: String
    private let distDir: String

    private(set) var isStale = false
    private(set) var sourceModifiedAt: Date?
    private(set) var lastBuiltAt: Date?
    private var previousSourceMtime: Date?
    private(set) var sourceSettled = false

    init(travelDataDir: String) {
        let expanded = NSString(string: travelDataDir).expandingTildeInPath
        self.srcDir = (expanded as NSString).appendingPathComponent("src")
        self.distDir = (expanded as NSString).appendingPathComponent("dist")
    }

    @discardableResult
    func check() -> Bool {
        let srcMtime = newestMtime(inDirectory: srcDir)
        let distMtime = newestMtime(inDirectory: distDir)

        sourceModifiedAt = srcMtime
        lastBuiltAt = distMtime

        if let src = srcMtime {
            if let dist = distMtime {
                isStale = src > dist
            } else {
                isStale = true
            }
        } else {
            isStale = false
        }

        sourceSettled = (srcMtime == previousSourceMtime)
        previousSourceMtime = srcMtime

        return isStale
    }

    private func newestMtime(inDirectory path: String) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return nil }
        var newest: Date?
        while let file = enumerator.nextObject() as? String {
            if file.hasPrefix(".") || file.contains("node_modules") { continue }
            let fullPath = (path as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest! {
                newest = mtime
            }
        }
        return newest
    }
}
