import SwiftUI

/// Asks for the GitHub Packages token. The token stays in a secure field; the
/// checker tests it with GitHub Packages and saves it in ~/.npmrc.
struct RegistryTokenSheet: View {
    let checker: EnvironmentChecker

    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.blue)
                Text("GitHub Packages token").font(.headline)
            }
            Text("pnpm needs a GitHub token with read:packages to download the @fastbreak-amateur packages. If the org uses SSO, authorise the token for it. Travel Runner tests the token, then saves it in ~/.npmrc after a copy of the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("ghp_… or github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit(save)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Create a token on GitHub",
                 destination: URL(string: "https://github.com/settings/tokens/new?scopes=read:packages&description=Travel%20Runner")!)
                .font(.caption)
            HStack {
                Button("Use my gh token") {
                    working = true
                    error = nil
                    Task {
                        switch await checker.ghToken() {
                        case .success(let value): token = value
                        case .failure(let failure): error = failure.text
                        }
                        working = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { checker.tokenEntryOpen = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Test and save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
        .interactiveDismissDisabled(working)
    }

    private func save() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            error = await checker.saveRegistryToken(token)?.text
            working = false
        }
    }
}
