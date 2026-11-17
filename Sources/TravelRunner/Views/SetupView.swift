import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SetupStep {
    case paths
    case environment
}

/// How the setup view ended.
enum SetupOutcome: Equatable {
    /// "Back": nothing was saved.
    case cancelled
    /// The paths are in services.json. `start` is true when the stack must
    /// start: "Save & Start" of the first run.
    case saved(start: Bool)
}

struct SetupView: View {
    let isFirstRun: Bool
    let onComplete: (SetupOutcome) -> Void

    @State private var currentStep: SetupStep = .paths
    @State private var checker: EnvironmentChecker?

    @State private var monorepoPath: String = ""
    @State private var universalLoginPath: String = ""
    @State private var streamServicesPath: String = ""
    @State private var loadTestPath: String = ""
    @State private var dropTargetHighlighted = false
    @State private var statusMessage: String? = nil
    @State private var statusKind: StatusKind = .success
    @State private var loadedExistingPaths = false
    /// The checkouts of the monorepo that the last drop found. Several give a chooser.
    @State private var monorepoCheckouts: [MonorepoCheckout] = []

    private enum StatusKind {
        case success, warning, error
    }

    var body: some View {
        switch currentStep {
        case .paths:
            step1Paths
        case .environment:
            if let checker {
                SetupStep2View(
                    checker: checker,
                    startsOnComplete: isFirstRun,
                    onBack: { currentStep = .paths },
                    onComplete: { start in
                        if savePaths() {
                            onComplete(.saved(start: start))
                        } else {
                            // Step 1 shows the error.
                            currentStep = .paths
                        }
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
                    Text(isFirstRun ? "Welcome to \(Flavor.current.displayName)" : "Settings — Repo Paths")
                        .font(.headline)
                    Text("Point to your local repos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isFirstRun {
                    Button("Back") { onComplete(.cancelled) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dropZone

                    repoRow(role: .monorepo, path: $monorepoPath)
                    if monorepoCheckouts.count > 1 {
                        checkoutChooser
                    }
                    repoRow(role: .universalLogin, path: $universalLoginPath)
                    repoRow(role: .streamServices, path: $streamServicesPath)
                    repoRow(role: .loadTest, path: $loadTestPath)

                    if let msg = statusMessage {
                        HStack {
                            switch statusKind {
                            case .success:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .warning:
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            case .error:
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
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

                    Button(action: { if savePaths() { onComplete(.saved(start: false)) } }) {
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
        // The first run keeps what was typed, also when the app quits before the end.
        .onChange(of: draft) { _, paths in
            if isFirstRun, loadedExistingPaths { SetupState.live.draftPaths = paths }
        }
    }

    // MARK: - Worktree chooser

    private var checkoutChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Several checkouts of \(Flavor.current.monorepoName) match. Choose the one to run:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Checkout", selection: $monorepoPath) {
                ForEach(monorepoCheckouts, id: \.path) { checkout in
                    Text("\(InstanceGuard.displayPath(checkout.path, home: NSHomeDirectory())) — \(checkout.label)")
                        .font(.system(.caption, design: .monospaced))
                        .tag(checkout.path)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06))
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(dropTargetHighlighted ? .blue : .secondary)
            Text("Drop your Codebases folder (or \(Flavor.current.monorepoName)) here")
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
                    HStack(spacing: 4) {
                        Text(role.rawValue)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.medium)
                        if !role.isRequired {
                            Text("optional")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
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

            if role == .monorepo, let mismatch = RepoDetector.flavorMismatch(path: path.wrappedValue) {
                Text(mismatch)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        RepoDetector.validate(path: monorepoPath, role: .monorepo)
            && RepoDetector.validate(path: universalLoginPath, role: .universalLogin)
    }

    private var draft: RepoPaths {
        RepoPaths(
            monorepo: monorepoPath.isEmpty ? nil : monorepoPath,
            universalLogin: universalLoginPath.isEmpty ? nil : universalLoginPath,
            streamServices: streamServicesPath.isEmpty ? nil : streamServicesPath,
            loadTest: loadTestPath.isEmpty ? nil : loadTestPath
        )
    }

    /// The paths are saved at the end, not here: a wizard that stops at the checks leaves no config.
    private func goToStep2() {
        checker = EnvironmentChecker(
            monorepoPath: monorepoPath,
            loginPath: universalLoginPath,
            streamServicesPath: streamServicesPath
        )
        currentStep = .environment
    }

    /// False when the config file could not be written. The message then names the file and the reason.
    private func savePaths() -> Bool {
        let paths = draft
        do {
            try ConfigLoader.generate(paths: paths)
            SetupState.live.markCompleted()
            statusMessage = "Saved"
            statusKind = .success
            return true
        } catch {
            statusMessage = "Could not save \(ConfigLoader.configPath): \(error.localizedDescription)"
            statusKind = .error
            return false
        }
    }

    private func loadExistingPaths() {
        // Once: "Back" from the checks must keep the paths that were typed.
        guard !loadedExistingPaths else { return }
        defer { loadedExistingPaths = true }
        // A first run that stopped before the end left its paths as a draft.
        let draft = isFirstRun ? SetupState.live.draftPaths : nil
        guard draft != nil || !ConfigLoader.isFirstRun else { return }
        let paths = draft ?? ConfigLoader.existingPaths()
        if let p = paths.monorepo, !p.isEmpty { monorepoPath = p }
        if let p = paths.universalLogin, !p.isEmpty { universalLoginPath = p }
        if let p = paths.streamServices, !p.isEmpty { streamServicesPath = p }
        if let p = paths.loadTest, !p.isEmpty { loadTestPath = p }
    }

    private func applyDetected(_ detected: DetectedRepos) {
        var filled: [String] = []

        monorepoCheckouts = detected.monorepoCheckouts
        if let p = detected.monorepo, monorepoPath.isEmpty || !RepoDetector.validate(path: monorepoPath, role: .monorepo) {
            monorepoPath = p
            filled.append(detected.monorepoCheckouts.count > 1
                ? "Monorepo (\(detected.monorepoCheckouts.count) checkouts — choose one below)"
                : "Monorepo")
        }
        if let p = detected.universalLogin, universalLoginPath.isEmpty {
            universalLoginPath = p
            filled.append("Universal Login")
        }
        if let p = detected.streamServices, streamServicesPath.isEmpty {
            streamServicesPath = p
            filled.append("Stream Services")
        }
        if let p = detected.loadTest, loadTestPath.isEmpty {
            loadTestPath = p
            filled.append("Travel Load Test")
        }

        var missing: [String] = []
        if monorepoPath.isEmpty { missing.append("Monorepo") }
        if universalLoginPath.isEmpty { missing.append("Universal Login") }

        if detected.monorepo == nil, monorepoPath.isEmpty,
           let other = detected.otherFlavorMonorepo, let mismatch = RepoDetector.flavorMismatch(path: other) {
            statusMessage = mismatch
            statusKind = .error
        } else if filled.isEmpty {
            statusMessage = "No new repos detected in this folder"
            statusKind = .warning
        } else if missing.isEmpty {
            statusMessage = "Found \(filled.joined(separator: ", "))"
            statusKind = .success
        } else {
            statusMessage = "Found \(filled.joined(separator: ", ")) — still need \(missing.joined(separator: ", "))"
            statusKind = .warning
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
