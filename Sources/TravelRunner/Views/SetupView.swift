import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SetupStep {
    case paths
    case environment
}

struct SetupView: View {
    let isFirstRun: Bool
    let onComplete: () -> Void

    @State private var currentStep: SetupStep = .paths
    @State private var checker: EnvironmentChecker?

    @State private var bookingPortalPath: String = ""
    @State private var universalLoginPath: String = ""
    @State private var travelDataPath: String = ""
    @State private var partnerPortalPath: String = ""
    @State private var dropTargetHighlighted = false
    @State private var statusMessage: String? = nil

    var body: some View {
        switch currentStep {
        case .paths:
            step1Paths
        case .environment:
            if let checker {
                SetupStep2View(
                    checker: checker,
                    onBack: { currentStep = .paths },
                    onComplete: {
                        savePaths()
                        onComplete()
                    }
                )
            }
        }
    }

    // MARK: - Step 1: Repo Paths

    private var step1Paths: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFirstRun ? "Welcome to Travel Runner" : "Settings — Repo Paths")
                        .font(.headline)
                    Text("Point to your local repos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isFirstRun {
                    Button("Back") { onComplete() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dropZone

                    repoRow(role: .bookingPortal, path: $bookingPortalPath)
                    repoRow(role: .universalLogin, path: $universalLoginPath)
                    repoRow(role: .travelData, path: $travelDataPath)
                    repoRow(role: .partnerPortal, path: $partnerPortalPath)

                    if let msg = statusMessage {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Spacer()
                if isFirstRun {
                    Button(action: goToStep2) {
                        Label("Next: Environment Check", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                    .controlSize(.regular)
                } else {
                    Button("Check Environment") { goToStep2() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!canProceed)

                    Button(action: { savePaths(); onComplete() }) {
                        Label("Save", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                    .controlSize(.regular)
                }
            }
            .padding(14)
        }
        .onAppear { loadExistingPaths() }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(dropTargetHighlighted ? .blue : .secondary)
            Text("Drop your Codebases folder here")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Auto-detects repos inside the folder")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    dropTargetHighlighted ? Color.blue : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(dropTargetHighlighted ? Color.blue.opacity(0.05) : Color.clear)
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            let detected = RepoDetector.scan(directory: url.path)
            applyDetected(detected)
            return detected.detectedCount > 0
        } isTargeted: { targeted in
            dropTargetHighlighted = targeted
        }
    }

    // MARK: - Repo Row

    private func repoRow(role: RepoDetector.RepoRole, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: role.icon)
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.rawValue)
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.medium)
                    Text(role.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !path.wrappedValue.isEmpty {
                    if RepoDetector.validate(path: path.wrappedValue, role: role) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Path to repo...", text: path)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Browse") { browseForFolder(path: path) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06))
        }
    }

    // MARK: - Actions

    private var canProceed: Bool {
        !bookingPortalPath.isEmpty && !universalLoginPath.isEmpty
    }

    private func goToStep2() {
        savePaths()
        checker = EnvironmentChecker(
            portalPath: bookingPortalPath,
            loginPath: universalLoginPath,
            travelDataPath: travelDataPath
        )
        currentStep = .environment
    }

    private func savePaths() {
        let repos = DetectedRepos(
            bookingPortal: bookingPortalPath,
            universalLogin: universalLoginPath,
            travelData: travelDataPath.isEmpty ? nil : travelDataPath,
            partnerPortal: partnerPortalPath.isEmpty ? nil : partnerPortalPath
        )
        do {
            try ConfigLoader.generate(from: repos)
            statusMessage = "Saved"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func loadExistingPaths() {
        guard !ConfigLoader.isFirstRun, let config = try? ConfigLoader.load() else { return }
        if let paths = config.paths {
            if let p = paths.bookingPortal, !p.isEmpty { bookingPortalPath = p }
            if let p = paths.universalLogin, !p.isEmpty { universalLoginPath = p }
            if let p = paths.travelData, !p.isEmpty { travelDataPath = p }
            if let p = paths.partnerPortal, !p.isEmpty { partnerPortalPath = p }
        }
        if bookingPortalPath.isEmpty || universalLoginPath.isEmpty {
            for service in config.services {
                switch service.id {
                case "supabase", "travel-portal":
                    if let cwd = service.cwd, bookingPortalPath.isEmpty { bookingPortalPath = cwd }
                case "universal-login":
                    if let cwd = service.cwd, universalLoginPath.isEmpty { universalLoginPath = cwd }
                default: break
                }
            }
        }
    }

    private func applyDetected(_ detected: DetectedRepos) {
        var filled: [String] = []

        if let p = detected.bookingPortal, bookingPortalPath.isEmpty {
            bookingPortalPath = p
            filled.append("Booking Portal")
        }
        if let p = detected.universalLogin, universalLoginPath.isEmpty {
            universalLoginPath = p
            filled.append("Universal Login")
        }
        if let p = detected.travelData, travelDataPath.isEmpty {
            travelDataPath = p
            filled.append("fb-travel-data")
        }
        if let p = detected.partnerPortal, partnerPortalPath.isEmpty {
            partnerPortalPath = p
            filled.append("Partner Portal")
        }

        var missing: [String] = []
        if bookingPortalPath.isEmpty { missing.append("Booking Portal") }
        if universalLoginPath.isEmpty { missing.append("Universal Login") }
        if travelDataPath.isEmpty { missing.append("fb-travel-data") }

        if filled.isEmpty {
            statusMessage = "No new repos detected in this folder"
        } else if missing.isEmpty {
            statusMessage = "All repos configured"
        } else {
            statusMessage = "Found \(filled.joined(separator: ", ")) — still need \(missing.joined(separator: ", "))"
        }
    }

    private func browseForFolder(path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the repo directory"
        panel.level = .floating
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
        }
    }
}
