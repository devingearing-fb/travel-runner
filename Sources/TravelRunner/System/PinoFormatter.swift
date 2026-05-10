import AppKit
import Foundation

enum PinoFormatter {
    struct FormattedLine {
        let text: String
        let color: NSColor
    }

    private static let standardKeys: Set<String> = [
        "level", "time", "pid", "hostname", "msg", "name", "v",
    ]

    static func format(_ entry: LogEntry, defaultColor: @Sendable (LogEntry) -> NSColor) -> FormattedLine {
        let raw = entry.text.trimmingCharacters(in: .whitespaces)

        // Try JSON parsing (raw pino output — the primary path)
        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return formatJSON(json)
        }

        // Non-JSON fallback: apply keyword-based coloring
        return formatPlainText(raw, entry: entry, defaultColor: defaultColor)
    }

    // MARK: - JSON formatting (primary path)

    private static func formatJSON(_ json: [String: Any]) -> FormattedLine {
        let level = resolveLevel(json["level"])
        let msg = json["msg"] as? String ?? ""
        let time = formatTime(json["time"])
        let module = json["module"] as? String

        // Build the main line: TIME LEVEL [module] message
        var parts: [String] = []
        if let t = time { parts.append(t) }
        parts.append(level.label)
        if let m = module { parts.append("[\(m)]") }
        if !msg.isEmpty { parts.append(msg) }

        // Collect extra fields
        let extraKeys = json.keys.filter { !standardKeys.contains($0) && $0 != "module" }
        if !extraKeys.isEmpty {
            let extras = extraKeys.sorted().compactMap { key -> String? in
                guard let val = json[key] else { return nil }
                let str = stringifyValue(val)
                // Skip very long values on the main line (show truncated)
                if str.count > 120 {
                    return "\(key)=\(str.prefix(80))..."
                }
                return "\(key)=\(str)"
            }
            if !extras.isEmpty {
                parts.append("| \(extras.joined(separator: "  "))")
            }
        }

        return FormattedLine(text: parts.joined(separator: " "), color: level.color)
    }

    // MARK: - Plain text fallback

    private static func formatPlainText(_ text: String, entry: LogEntry, defaultColor: @Sendable (LogEntry) -> NSColor) -> FormattedLine {
        let lower = text.lowercased()

        // Next.js compile messages
        if text.contains("✓ Compiled") || text.contains("✓ Ready") {
            return FormattedLine(text: text, color: .systemGreen)
        }
        if text.contains("○ Compiling") || text.contains("◐") {
            return FormattedLine(text: text, color: .systemCyan)
        }
        if text.contains("⨯") || lower.contains("error") {
            return FormattedLine(text: text, color: .systemRed)
        }
        if lower.contains("warn") || lower.contains("insecure") {
            return FormattedLine(text: text, color: .systemOrange)
        }

        // Stack traces
        if text.contains("    at ") || text.hasPrefix("          ") {
            return FormattedLine(text: text, color: NSColor.systemGray.withAlphaComponent(0.6))
        }

        return FormattedLine(text: text, color: defaultColor(entry))
    }

    // MARK: - Level resolution

    private struct Level {
        let label: String
        let color: NSColor
    }

    private static func resolveLevel(_ value: Any?) -> Level {
        if let num = value as? Int {
            return switch num {
            case ..<20:   Level(label: "TRC", color: .systemGray)
            case 20..<30: Level(label: "DBG", color: .systemGray)
            case 30..<40: Level(label: "INF", color: .systemGreen)
            case 40..<50: Level(label: "WRN", color: .systemOrange)
            case 50..<60: Level(label: "ERR", color: .systemRed)
            default:      Level(label: "FTL", color: .systemRed)
            }
        }
        if let str = value as? String {
            return switch str.lowercased() {
            case "trace": Level(label: "TRC", color: .systemGray)
            case "debug": Level(label: "DBG", color: .systemGray)
            case "info":  Level(label: "INF", color: .systemGreen)
            case "warn":  Level(label: "WRN", color: .systemOrange)
            case "error": Level(label: "ERR", color: .systemRed)
            case "fatal": Level(label: "FTL", color: .systemRed)
            default:      Level(label: str.prefix(3).uppercased(), color: .white)
            }
        }
        return Level(label: "???", color: .white)
    }

    // MARK: - Helpers

    private static func formatTime(_ value: Any?) -> String? {
        guard let ms = value as? Double else {
            if let ms = value as? Int {
                return formatTimestamp(Double(ms))
            }
            return nil
        }
        return formatTimestamp(ms)
    }

    private static func formatTimestamp(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func stringifyValue(_ value: Any) -> String {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            return num.stringValue
        case let dict as [String: Any]:
            if let type = dict["type"] as? String, type == "Error",
               let message = dict["message"] as? String {
                return "Error: \(message)"
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\(dict)"
        case let arr as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: []),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\(arr)"
        default:
            return "\(value)"
        }
    }
}
