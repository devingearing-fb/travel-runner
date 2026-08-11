import SwiftUI

struct DbSeedScenarioSelectorView: View {
    let scenarios: [DbSeedScenario]
    let selectedID: String?
    let selectedScenario: DbSeedScenario?
    let loadError: String?
    let isRunning: Bool
    let onSelect: (String) -> Void
    let onReload: () -> Void

    @State private var hoveredScenarioID: String?
    @FocusState private var focusedScenarioID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SeedScenarioTokens.sectionSpacing) {
            Text("Choose the repository-owned data set for the next database reset. Selecting a scenario does not change or reset the current database.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isRunning {
                runningState
            }

            if let loadError {
                catalogState(
                    title: scenarios.isEmpty ? "Scenario folders unavailable" : "Saved scenario unavailable",
                    message: loadError,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .red
                )
            }

            if scenarios.isEmpty {
                if loadError == nil {
                    catalogState(
                        title: "No seed scenarios found",
                        message: "Reload the repository scenario folders before resetting the database.",
                        systemImage: "tray",
                        color: .orange
                    )
                }
            } else {
                if selectedScenario == nil && loadError == nil {
                    invalidSelectionState
                }

                LazyVStack(spacing: SeedScenarioTokens.cardSpacing) {
                    ForEach(scenarios, id: \.id) { scenario in
                        scenarioButton(scenario)
                    }
                }
            }
        }
    }

    private var runningState: some View {
        HStack(alignment: .top, spacing: SeedScenarioTokens.inlineSpacing) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: SeedScenarioTokens.textSpacing) {
                Text("Database setup is running")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                Text("Scenario selection is locked until the current setup finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SeedScenarioTokens.statePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                .fill(Color.blue.opacity(SeedScenarioTokens.stateFillOpacity))
        }
        .accessibilityElement(children: .combine)
    }

    private var invalidSelectionState: some View {
        HStack(alignment: .top, spacing: SeedScenarioTokens.inlineSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: SeedScenarioTokens.textSpacing) {
                Text("Choose a valid scenario")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                Text(invalidSelectionMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SeedScenarioTokens.statePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                .fill(Color.orange.opacity(SeedScenarioTokens.stateFillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                .strokeBorder(Color.orange.opacity(SeedScenarioTokens.stateBorderOpacity))
        }
        .accessibilityElement(children: .combine)
    }

    private var invalidSelectionMessage: String {
        if let selectedID {
            return "The saved selection \u{201c}\(selectedID)\u{201d} is not in the repository scenario folders. Choose an available scenario before resetting."
        }
        return "No scenario is selected. Choose an available scenario before resetting."
    }

    private func catalogState(
        title: String,
        message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: SeedScenarioTokens.inlineSpacing) {
            HStack(alignment: .top, spacing: SeedScenarioTokens.inlineSpacing) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: SeedScenarioTokens.textSpacing) {
                    Text(title)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("Reload Scenarios", action: onReload)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Reloads seed scenarios from the repository scenario folders")
        }
        .padding(SeedScenarioTokens.statePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                .fill(color.opacity(SeedScenarioTokens.stateFillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                .strokeBorder(color.opacity(SeedScenarioTokens.stateBorderOpacity))
        }
    }

    private func scenarioButton(_ scenario: DbSeedScenario) -> some View {
        let isSelected = scenario.id == selectedScenario?.id
        let isHovered = hoveredScenarioID == scenario.id && !isRunning
        let isFocused = focusedScenarioID == scenario.id && !isRunning
        return Button {
            onSelect(scenario.id)
        } label: {
            VStack(alignment: .leading, spacing: SeedScenarioTokens.cardContentSpacing) {
                HStack(alignment: .top, spacing: SeedScenarioTokens.inlineSpacing) {
                    Text(scenario.name)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: SeedScenarioTokens.inlineSpacing)

                    if isSelected {
                        Label("SELECTED", systemImage: "checkmark")
                            .font(.system(size: SeedScenarioTokens.badgeFontSize, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, SeedScenarioTokens.badgeHorizontalPadding)
                            .padding(.vertical, SeedScenarioTokens.badgeVerticalPadding)
                            .background {
                                RoundedRectangle(cornerRadius: SeedScenarioTokens.badgeCornerRadius)
                                    .fill(Color.blue.opacity(SeedScenarioTokens.badgeFillOpacity))
                            }
                    }
                }

                Text(scenario.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: SeedScenarioTokens.textSpacing) {
                    Text("SEED FILE ORDER")
                        .font(.system(size: SeedScenarioTokens.fileLabelFontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(scenario.fileSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !scenario.variables.isEmpty {
                    VStack(alignment: .leading, spacing: SeedScenarioTokens.textSpacing) {
                        Text("VARIABLES")
                            .font(.system(size: SeedScenarioTokens.fileLabelFontSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(scenario.variables, id: \.name) { variable in
                            Text("\(variable.name): \(variable.value)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(SeedScenarioTokens.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                    .fill(cardFill(isSelected: isSelected, isHovered: isHovered, isFocused: isFocused))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SeedScenarioTokens.cornerRadius)
                    .strokeBorder(
                        cardBorder(isSelected: isSelected, isHovered: isHovered, isFocused: isFocused),
                        lineWidth: SeedScenarioTokens.borderWidth
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? SeedScenarioTokens.disabledOpacity : SeedScenarioTokens.enabledOpacity)
        .focusable(!isRunning)
        .focused($focusedScenarioID, equals: scenario.id)
        .onHover { isHovering in
            if isHovering {
                hoveredScenarioID = scenario.id
            } else if hoveredScenarioID == scenario.id {
                hoveredScenarioID = nil
            }
        }
        .accessibilityLabel(Text(accessibilityLabel(for: scenario)))
        .accessibilityValue(isSelected ? "Selected for the next reset" : "Not selected")
        .accessibilityHint(
            isRunning
                ? "Unavailable while database setup is running"
                : "Selects this scenario for the next reset. This does not change the current database"
        )
    }

    private func accessibilityLabel(for scenario: DbSeedScenario) -> String {
        var sections = [
            scenario.name,
            scenario.description,
            "Seed file order: \(scenario.fileSummary)",
        ]
        if !scenario.variables.isEmpty {
            let variables = scenario.variables
                .map { "\($0.name): \($0.value)" }
                .joined(separator: ", ")
            sections.append("Variables: \(variables)")
        }
        return sections.joined(separator: ". ")
    }

    private func cardFill(isSelected: Bool, isHovered: Bool, isFocused: Bool) -> Color {
        if isSelected {
            return Color.blue.opacity(
                isFocused
                    ? SeedScenarioTokens.focusedSelectedFillOpacity
                    : SeedScenarioTokens.selectedFillOpacity
            )
        }
        if isHovered || isFocused {
            return Color.secondary.opacity(SeedScenarioTokens.hoverFillOpacity)
        }
        return Color.secondary.opacity(SeedScenarioTokens.idleFillOpacity)
    }

    private func cardBorder(isSelected: Bool, isHovered: Bool, isFocused: Bool) -> Color {
        if isFocused {
            return Color.blue.opacity(SeedScenarioTokens.focusedBorderOpacity)
        }
        if isSelected {
            return Color.blue.opacity(SeedScenarioTokens.selectedBorderOpacity)
        }
        if isHovered {
            return Color.secondary.opacity(SeedScenarioTokens.hoverBorderOpacity)
        }
        return Color.secondary.opacity(SeedScenarioTokens.idleBorderOpacity)
    }
}

private enum SeedScenarioTokens {
    static let sectionSpacing: CGFloat = 8
    static let cardSpacing: CGFloat = 8
    static let cardContentSpacing: CGFloat = 6
    static let inlineSpacing: CGFloat = 8
    static let textSpacing: CGFloat = 4
    static let cardPadding: CGFloat = 12
    static let statePadding: CGFloat = 12
    static let cornerRadius: CGFloat = 6
    static let badgeCornerRadius: CGFloat = 3
    static let badgeHorizontalPadding: CGFloat = 6
    static let badgeVerticalPadding: CGFloat = 2
    static let borderWidth: CGFloat = 1
    static let badgeFontSize: CGFloat = 9
    static let fileLabelFontSize: CGFloat = 9
    static let enabledOpacity = 1.0
    static let disabledOpacity = 0.52
    static let selectedFillOpacity = 0.12
    static let focusedSelectedFillOpacity = 0.17
    static let hoverFillOpacity = 0.1
    static let idleFillOpacity = 0.06
    static let selectedBorderOpacity = 0.55
    static let focusedBorderOpacity = 0.9
    static let hoverBorderOpacity = 0.28
    static let idleBorderOpacity = 0.14
    static let badgeFillOpacity = 0.12
    static let stateFillOpacity = 0.06
    static let stateBorderOpacity = 0.28
}
