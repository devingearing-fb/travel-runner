import SwiftUI

struct ServiceChipBar: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Binding var selectedServiceID: String?
    let failingCount: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chipButton(id: nil, label: "All", color: .accentColor, shortcut: "1")

                if failingCount >= 2 {
                    chipButton(
                        id: "__cascade__",
                        label: "\(failingCount) Failing",
                        color: .red,
                        shortcut: nil,
                        icon: "exclamationmark.triangle.fill"
                    )
                }

                ForEach(Array(supervisor.sortedServiceIDs.enumerated()), id: \.element) { index, id in
                    let state = supervisor.serviceStates[id]
                    let name = state?.definition.displayName ?? id
                    let abbrev = abbreviate(name)
                    let color = state?.phase.color ?? .gray
                    let shortcut = index < 8 ? "\(index + 2)" : nil
                    chipButton(id: id, label: abbrev, color: color, shortcut: shortcut)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func chipButton(
        id: String?,
        label: String,
        color: Color,
        shortcut: String?,
        icon: String? = nil
    ) -> some View {
        let isSelected = selectedServiceID == id

        Button {
            selectedServiceID = id
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                        .foregroundStyle(color)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.2) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                isSelected
                    ? RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.4), lineWidth: 1)
                    : nil
            )
        }
        .buttonStyle(.borderless)
        .modifier(OptionalKeyboardShortcut(key: shortcut))
    }

    private func abbreviate(_ name: String) -> String {
        if name.count <= 6 { return name }
        let words = name.split(separator: " ")
        if words.count > 1 {
            return words.map { String($0.prefix(1)) }.joined().uppercased()
        }
        let parts = name.split(separator: "-")
        if parts.count > 1 {
            return parts.map { String($0.prefix(3)) }.joined()
        }
        return String(name.prefix(5))
    }
}

private struct OptionalKeyboardShortcut: ViewModifier {
    let key: String?

    func body(content: Content) -> some View {
        if let key, let char = key.first {
            content.keyboardShortcut(KeyEquivalent(char), modifiers: .command)
        } else {
            content
        }
    }
}
