import Foundation

/// Why a recording could not start.
enum UniConnectDictationRecorderError: Error, Equatable {
    /// macOS gave no input device, or it refused the settings.
    case couldNotStart
}
