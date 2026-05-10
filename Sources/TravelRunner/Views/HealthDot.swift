import SwiftUI

struct HealthDot: View {
    let status: HealthStatus

    var body: some View {
        Image(systemName: status.iconName)
            .foregroundStyle(status.color)
    }
}
