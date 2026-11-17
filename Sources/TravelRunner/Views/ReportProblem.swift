import AppKit

/// The "Report a problem" action of every entry point: the menu bar, the triage
/// card, a failed DB step, the Issues detail, Diagnostics and the error banner.
@MainActor
enum ReportProblem {
    /// Set after the person saw the sheet about what the report holds.
    static let noticeShownKey = "reportPrivacyNoticeShown"

    /// The first report shows the sheet first. Then the zip is saved to Downloads
    /// and shown in Finder, the summary is copied, and a toast says so.
    static func run(
        _ focus: ReportExporter.Focus = .general,
        supervisor: EnvironmentSupervisor,
        defaults: UserDefaults = .standard
    ) {
        guard !supervisor.reportExportRunning else { return }
        guard defaults.bool(forKey: noticeShownKey) else {
            showNotice { confirmed in
                guard confirmed else { return }
                defaults.set(true, forKey: noticeShownKey)
                save(focus, supervisor: supervisor)
            }
            return
        }
        save(focus, supervisor: supervisor)
    }

    private static func showNotice(_ completion: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Report a problem"
        alert.informativeText = ReportExporter.privacyNotice
        alert.addButton(withTitle: "Save Report")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in completion(response == .alertFirstButtonReturn) }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private static func save(_ focus: ReportExporter.Focus, supervisor: EnvironmentSupervisor) {
        Task {
            do {
                let report = try await supervisor.exportReport(focus: focus)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.summary, forType: .string)
                NSWorkspace.shared.activateFileViewerSelecting([report.zipURL])
                supervisor.onActionFeedback?(report.message, true)
            } catch {
                supervisor.onActionFeedback?("Report not saved: \(error.localizedDescription)", false)
            }
        }
    }
}
