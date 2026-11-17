import Foundation

/// One fix that a button can run. It serves the service rows, the DB steps and the
/// fix buttons of the checks (plan 4.0, item 5).
///
/// Merge note: F4 defines this enum, with its button titles, in
/// `Models/ServiceCondition.swift`. The cases here are the same. When F4 is on this
/// branch, delete this file and keep F4's enum.
enum RecoveryAction: Equatable, Hashable, Sendable {
    case restart
    case startService
    case stopForeignAndRetry(port: Int?)
    case openContainerRuntime
    case installDependencies
    case clearCacheAndRestart
    case openLog
    case stripeLogin
    case installStripe
    case updateStripe
    case importSharedEnv
    case redownloadHotels
    case resetWithoutHotels
    case retryFromStep
    case ghAuth
    case openHealth
    case openSettingsPaths
}
