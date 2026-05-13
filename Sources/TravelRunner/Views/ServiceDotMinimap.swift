import SwiftUI

struct ServiceDotMinimap: View {
    let serviceStates: [String: ServiceState]
    let sortedIDs: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(sortedIDs, id: \.self) { id in
                if let state = serviceStates[id] {
                    Circle()
                        .fill(state.phase.color)
                        .frame(width: 6, height: 6)
                        .help("\(state.definition.displayName): \(state.phase.rawValue)")
                }
            }
        }
    }
}
