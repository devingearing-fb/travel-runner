import SwiftUI

@Observable
@MainActor
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let style: Style
    }

    enum Style {
        case success, error, info

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

    private(set) var toasts: [Toast] = []

    func show(_ message: String, style: Style = .info, duration: Duration = .seconds(4)) {
        let toast = Toast(message: message, style: style)
        toasts.append(toast)
        if toasts.count > 3 {
            toasts.removeFirst(toasts.count - 3)
        }
        Task {
            try? await Task.sleep(for: duration)
            toasts.removeAll { $0.id == toast.id }
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
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(toast.style.color.opacity(0.4))
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.2), value: center.toasts)
        .allowsHitTesting(false)
    }
}
