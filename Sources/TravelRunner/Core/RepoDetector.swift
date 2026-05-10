import Foundation

struct DetectedRepos: Sendable {
    var bookingPortal: String?
    var universalLogin: String?
    var travelData: String?

    var allDetected: Bool {
        bookingPortal != nil && universalLogin != nil && travelData != nil
    }

    var detectedCount: Int {
        [bookingPortal, universalLogin, travelData].compactMap { $0 }.count
    }
}

enum RepoDetector {
    static func scan(directory: String) -> DetectedRepos {
        let fm = FileManager.default
        let path = NSString(string: directory).expandingTildeInPath
        var result = DetectedRepos()

        guard let children = try? fm.contentsOfDirectory(atPath: path) else {
            return result
        }

        for child in children {
            let childPath = (path as NSString).appendingPathComponent(child)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            checkDirectory(childPath, name: child, result: &result)

            // Also scan one level deeper (e.g., "TRAVEL BOOKING/fb-travel-data")
            if let grandchildren = try? fm.contentsOfDirectory(atPath: childPath) {
                for gc in grandchildren {
                    let gcPath = (childPath as NSString).appendingPathComponent(gc)
                    var gcIsDir: ObjCBool = false
                    if fm.fileExists(atPath: gcPath, isDirectory: &gcIsDir), gcIsDir.boolValue {
                        checkDirectory(gcPath, name: gc, result: &result)
                    }
                }
            }
        }

        return result
    }

    static func validate(path: String, role: RepoRole) -> Bool {
        let fm = FileManager.default
        let expanded = NSString(string: path).expandingTildeInPath
        switch role {
        case .bookingPortal:
            return fm.fileExists(atPath: (expanded as NSString).appendingPathComponent("supabase/config.toml"))
        case .universalLogin:
            return fm.fileExists(atPath: (expanded as NSString).appendingPathComponent("package.json"))
        case .travelData:
            return fm.fileExists(atPath: (expanded as NSString).appendingPathComponent("package.json"))
        }
    }

    private static func checkDirectory(_ path: String, name: String, result: inout DetectedRepos) {
        let fm = FileManager.default

        // Booking portal: has supabase/config.toml AND src/app (Next.js app router)
        // This distinguishes it from fb-travel-data which also has supabase/config.toml
        if result.bookingPortal == nil {
            let supabaseConfig = (path as NSString).appendingPathComponent("supabase/config.toml")
            let srcApp = (path as NSString).appendingPathComponent("src/app")
            if fm.fileExists(atPath: supabaseConfig) && fm.fileExists(atPath: srcApp) {
                result.bookingPortal = path
            }
        }

        // Universal login: directory name contains "universal-login"
        if result.universalLogin == nil {
            if name.lowercased().contains("universal-login") {
                let pkg = (path as NSString).appendingPathComponent("package.json")
                if fm.fileExists(atPath: pkg) {
                    result.universalLogin = path
                }
            }
        }

        // Travel data: package.json name contains "fb-travel-data"
        if result.travelData == nil {
            let pkg = (path as NSString).appendingPathComponent("package.json")
            if fm.fileExists(atPath: pkg),
               let data = fm.contents(atPath: pkg),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pkgName = json["name"] as? String,
               pkgName.contains("fb-travel-data") {
                result.travelData = path
            }
        }
    }

    enum RepoRole: String, CaseIterable, Sendable {
        case bookingPortal = "Travel Booking Portal"
        case universalLogin = "Universal Login"
        case travelData = "fb-travel-data"

        var description: String {
            switch self {
            case .bookingPortal: "Supabase, dev server, yalc link target"
            case .universalLogin: "Auth gateway (port 3000)"
            case .travelData: "Shared domain package (yalc publish source)"
            }
        }

        var icon: String {
            switch self {
            case .bookingPortal: "globe"
            case .universalLogin: "person.badge.key"
            case .travelData: "shippingbox"
            }
        }
    }
}
