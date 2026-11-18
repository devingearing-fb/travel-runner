import SwiftUI

@Observable
@MainActor
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let style: Style
        var serviceID: String? = nil

        /// An error stays until the person closes it, and a click opens its triage card.
        var opensTriage: Bool { style == .error }
    }

    typealias Style = ActionFeedback.Style

    /// The most toasts on screen at once.
    static let limit = 3

    private(set) var toasts: [Toast] = []
    /// A click on an error toast.
    var onOpen: ((Toast) -> Void)?

    /// How long a toast stays. Nil: until the person closes it.
    static func duration(for style: Style) -> Duration? {
        style == .error ? nil : .seconds(4)
    }

    func show(_ feedback: ActionFeedback) {
        show(feedback.message, style: feedback.style, serviceID: feedback.serviceID)
    }

    func show(_ message: String, style: Style = .info, serviceID: String? = nil) {
        let toast = Toast(message: message, style: style, serviceID: serviceID)
        toasts.append(toast)
        // Too many: the oldest goes first, a short-lived one before an error.
        while toasts.count > Self.limit {
            let index = toasts.firstIndex { !$0.opensTriage } ?? 0
            toasts.remove(at: index)
        }
        guard let duration = Self.duration(for: style) else { return }
        Task {
            try? await Task.sleep(for: duration)
            dismiss(toast.id)
        }
    }

    func dismiss(_ id: Toast.ID) {
        toasts.removeAll { $0.id == id }
    }

    func open(_ toast: Toast) {
        dismiss(toast.id)
        onOpen?(toast)
    }
}

extension ActionFeedback.Style {
    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .info: .blue
        }
    }
}

struct ToastOverlay: View {
    let center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            ForEach(center.toasts) { toast in
                HStack(spacing: 6) {
                    Image(systemName: toast.style.icon)
                        .font(.caption)
                        .foregroundStyle(toast.style.color)
                    Text(toast.message)
                        .font(.caption)
                        .lineLimit(toast.opensTriage ? 4 : 2)
                    if toast.opensTriage {
                        Button {
                            center.dismiss(toast.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Close")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(toast.style.color.opacity(0.4))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { if toast.opensTriage { center.open(toast) } }
                .help(toast.opensTriage ? "Open Status" : "")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.2), value: center.toasts)
    }
}
