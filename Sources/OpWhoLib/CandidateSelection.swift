import Foundation

/// A trigger-process candidate paired with the metadata we use to pick the
/// best one when several are detected at the moment a 1Password dialog opens.
struct TriggerCandidate {
    let entry: OverlayPanel.ProcessEntry
    let kind: RequestKind
    let startTime: Date?

    init(entry: OverlayPanel.ProcessEntry, kind: RequestKind, startTime: Date?) {
        self.entry = entry
        self.kind = kind
        self.startTime = startTime
    }
}

/// Fold `op` helper children into their `op` parent.
///
/// 1Password's CLI forks a biometric-helper child whose argv and signature
/// verification are inaccessible to us. The user-visible command — the one
/// the user actually typed — is the *parent* `op` process up the chain.
/// This function walks the chain, dropping each leading `op` node that has
/// another `op` node as its direct parent in the chain, until we reach a
/// node that is no longer being shadowed.
public func foldOpHelper(chain: [ProcessNode]) -> [ProcessNode] {
    var c = chain
    while c.count >= 2,
          c[0].name == "op",
          !c[0].isVerifiedOnePasswordCLI,
          c[1].name == "op" {
        c.removeFirst()
    }
    return c
}

/// Pick the single best candidate among multiple triggers detected at the
/// moment a 1Password dialog appeared.
///
/// Ranking, most preferred first:
///   1. `.onePasswordCLI` (verified `op` binary)
///   2. `.ssh` (real network operation)
///   3. `.unknown` (unrecognized but valid candidate)
///   4. `.unverifiedOp` (last resort — usually a helper we failed to fold)
///
/// Within the same rank, the oldest (earliest start time) wins — newer
/// processes are usually downstream consequences, and 1Password queues
/// approval requests in arrival order, so the oldest pending request is
/// the one the dialog is for.
func selectBestCandidate(_ candidates: [TriggerCandidate]) -> TriggerCandidate? {
    return candidates.min(by: { a, b in
        let pa = kindRank(a.kind)
        let pb = kindRank(b.kind)
        if pa != pb { return pa < pb }
        switch (a.startTime, b.startTime) {
        case let (sa?, sb?): return sa < sb
        case (nil, _?):      return false
        case (_?, nil):      return true
        case (nil, nil):     return false
        }
    })
}

private func kindRank(_ kind: RequestKind) -> Int {
    switch kind {
    case .onePasswordCLI: return 0
    case .ssh:            return 1
    case .unknown:        return 2
    case .unverifiedOp:   return 3
    }
}
