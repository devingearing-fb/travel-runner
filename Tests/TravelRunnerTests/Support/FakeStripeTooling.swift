import Foundation
import os
@testable import TravelRunner

/// A `StripeTooling` that runs no CLI. A test gives the answer and reads how often
/// it was asked.
final class FakeStripeTooling: StripeTooling, @unchecked Sendable {
    typealias Answer = @Sendable (StripeKeyResolution) async -> StripeAvailability

    private let asked = OSAllocatedUnfairLock(initialState: 0)
    private let answer: Answer

    init(_ answer: @escaping Answer) {
        self.answer = answer
    }

    /// The CLI runs, in the mode of the resolution.
    static var available: FakeStripeTooling { FakeStripeTooling { .ok($0.mode) } }

    static func answering(_ availability: StripeAvailability) -> FakeStripeTooling {
        FakeStripeTooling { _ in availability }
    }

    var calls: Int { asked.withLock { $0 } }

    func availability(_ resolution: StripeKeyResolution) async -> StripeAvailability {
        asked.withLock { $0 += 1 }
        return await answer(resolution)
    }
}
