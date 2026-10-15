import Foundation

struct DetectedRepos: Sendable {
    var monorepo: String?
    var universalLogin: String?
    var streamServices: String?
    var loadTest: String?

    var allDetected: Bool {
        monorepo != nil && universalLogin != nil && streamServices != nil && loadTest != nil
    }

    var detectedCount: Int {
        [monorepo, universalLogin, streamServices, loadTest].compactMap { $0 }.count
    }
}

enum RepoDetector {
    /// Scans the dropped folder itself, its children and its grandchildren.
    static func scan(directory: String) -> DetectedRepos {
        let fm = FileManager.default
        let path = NSString(string: directory).expandingTildeInPath
        var result = DetectedRepos()
        checkDirectory(path, result: &result)

        for child in subdirectories(of: path) {
            checkDirectory(child, result: &result)
            // One level deeper too (e.g. "Codebases/TRAVEL BOOKING/fb-travel-monolith"),
            // but never inside the monorepo itself.
            guard !isMonorepo(child) else { continue }
            for grandchild in subdirectories(of: child) where fm.fileExists(atPath: grandchild) {
                checkDirectory(grandchild, result: &result)
            }
        }
        return result
    }

    static func validate(path: String, role: RepoRole) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        switch role {
        case .monorepo:
            return isMonorepo(expanded)
        case .universalLogin, .streamServices, .loadTest:
            return FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent("package.json"))
        }
    }

    /// The fb-travel monorepo: a pnpm workspace with the booking app and the shared supabase/ directory.
    static func isMonorepo(_ path: String) -> Bool {
        let fm = FileManager.default
        return ["pnpm-workspace.yaml", "apps/booking-portal/package.json", "supabase/config.toml"].allSatisfy {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
    }

    /// Finds the monorepo for a config that still points at an old sibling repo: the path
    /// itself or one of its ancestors, then the siblings at each of the three levels above it.
    static func findMonorepo(near path: String) -> String? {
        var current = NSString(string: path).expandingTildeInPath
        for _ in 0..<3 {
            if isMonorepo(current) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { break }
            if let sibling = subdirectories(of: parent).sorted().first(where: isMonorepo) {
                return sibling
            }
            current = parent
        }
        return nil
    }

    private static func subdirectories(of path: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let child = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: child, isDirectory: &isDir) && isDir.boolValue ? child : nil
        }
    }

    private static func packageName(at path: String) -> String? {
        let pkg = (path as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: pkg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    private static func checkDirectory(_ path: String, result: inout DetectedRepos) {
        let name = (path as NSString).lastPathComponent.lowercased()

        if result.monorepo == nil, isMonorepo(path) {
            result.monorepo = path
            return
        }

        // Universal login: identified by directory name (its package name is unrelated).
        if result.universalLogin == nil, name.contains("universal-login"), packageName(at: path) != nil {
            result.universalLogin = path
        }

        switch packageName(at: path) {
        case "fb-amateur-stream-services" where result.streamServices == nil:
            result.streamServices = path
        case "@fastbreak-amateur/travel-load-test" where result.loadTest == nil:
            result.loadTest = path
        default:
            break
        }
    }

    enum RepoRole: String, CaseIterable, Sendable {
        case monorepo = "fb-travel Monorepo"
        case universalLogin = "Universal Login"
        case streamServices = "Stream Services"
        case loadTest = "Travel Load Test"

        var description: String {
            switch self {
            case .monorepo: "Supabase, booking portal (3002), partner portal (3006), travel-data"
            case .universalLogin: "Auth gateway (port 3000)"
            case .streamServices: "CDC ingest and reaction worker (port 3003)"
            case .loadTest: "Verification runs for the full profile"
            }
        }

        var icon: String {
            switch self {
            case .monorepo: "shippingbox"
            case .universalLogin: "person.badge.key"
            case .streamServices: "arrow.triangle.branch"
            case .loadTest: "gauge.with.dots.needle.67percent"
            }
        }

        /// Repos the core profiles need. Stream services and the load test serve only `full`.
        var isRequired: Bool {
            switch self {
            case .monorepo, .universalLogin: true
            case .streamServices, .loadTest: false
            }
        }
    }
}
