/// The deliberately non-diagnostic result of resolving one SSH destination.
enum UniConnectSSHTargetResolutionOutcome: Equatable, Sendable {
    case resolved(UniConnectSSHEffectiveTarget)
    case indeterminate
}
