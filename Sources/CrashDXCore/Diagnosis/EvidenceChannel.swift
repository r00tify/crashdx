import Foundation

/// Which artifact inside the `.ips` payload a `Fact` was read from.
///
/// Stage 3's default `additive` scoring treats every supporting Fact as an independent
/// signal, so a rule that cites three Facts at weights 3/2/1 reaches `strong` (>= 4) on
/// what may be a single underlying observation rendered three ways. The canonical example
/// is `WatchdogTimeoutRule`: `termination.code` (0x8badf00d, weight 3),
/// `termination.namespace` (weight 1) and `termination.watchdog-event` (weight 2) sum to
/// 6, but ReportCrash writes all three into one `termination` dict from one launchd
/// decision — the namespace and the reason text exist *because* the code is 0x8badf00d.
/// One signal, scored as three.
///
/// A channel is the unit `DiagnosisEngine.Scoring.channelCapped` collapses: within a
/// channel only the single highest-weighted Fact counts.
///
/// **The channel is deliberately defined as the source artifact, not "the underlying
/// event".** Source artifact is objective and mechanically derivable (see `of(_:)`, which
/// reads `Fact.sourcePath`), so it stays correct as extractors are added without anyone
/// maintaining a table. Event-level correlation is a judgement call and this enum does not
/// attempt it — see `residualCorrelationNote` for what that leaves on the table.
public enum EvidenceChannel: String, Codable, Sendable, CaseIterable {
    /// The Mach exception record: type, signal, codes, subtype, and the faulting address
    /// `MemoryFactsExtractor` parses back out of subtype/codes. The kernel writes all of
    /// these together from one exception, and the address-classification Facts
    /// (`memory.fault-address-null-page`, `-exactly-null`) are pure re-readings of the
    /// same number.
    case machException = "mach-exception"
    /// The `termination` dict: launchd's/the kernel's stated reason for killing the
    /// process, in whatever rendering — coded (`termination.code`), named
    /// (`termination.namespace`), or freetext (`termination.reason-text` and the
    /// watchdog/jetsam Facts mined out of it).
    case termination
    /// Application Specific Information.
    case asi
    /// The faulting thread's unwound frames: sentinels, deepest app frame, the recursion
    /// signature.
    case threadFrames = "thread-frames"
    /// The faulting thread's register file.
    case threadState = "thread-state"
    /// `lastExceptionBacktrace`. Distinct from `threadFrames` even when it records the
    /// same throw: it is written by the ObjC runtime's uncaught handler rather than by the
    /// crash-time unwind, and CLAUDE.md's ground truth is that ReportCrash mis-symbolicates
    /// the two *independently*. Agreement between them is therefore real corroboration,
    /// not an echo.
    case lastExceptionBacktrace = "last-exception-backtrace"
    /// `vmregioninfo`: the VM map as of the crash. Not derivable from the faulting address
    /// alone, which is why it can contradict an address-value inference (see
    /// `NullDereferenceRule` and its STACK GUARD case).
    case vmRegion = "vm-region"
    /// No recognised source-artifact root. Scored as its own channel per Fact, i.e. no
    /// capping, so an unmapped Fact never silently loses weight.
    case other

    /// The channel a Fact belongs to, derived from its `sourcePath` root.
    ///
    /// Deriving rather than tabulating means a new extractor is classified correctly the
    /// day it lands, provided it honours `Fact.sourcePath`'s contract of pointing at the
    /// payload location the Fact was actually read from. `unclassifiedIsPerFact` below is
    /// the safety valve for paths this doesn't recognise.
    public static func of(_ fact: Fact) -> EvidenceChannel {
        let path = fact.sourcePath
        let root = path.prefix { $0 != "." && $0 != "[" }

        switch root {
        case "exception": return .machException
        case "termination": return .termination
        case "asi": return .asi
        case "lastExceptionBacktrace": return .lastExceptionBacktrace
        case "vmregioninfo": return .vmRegion
        case "threads":
            // threads[N].threadState.far vs threads[N].frames[M] — same root, two
            // independently written structures.
            if path.contains(".threadState") { return .threadState }
            if path.contains(".frames") { return .threadFrames }
            return .other
        default: return .other
        }
    }

    /// Facts in `.other` are NOT pooled with each other: an unrecognised source path means
    /// "channel unknown", and pooling unknowns would let one unmapped Fact silently
    /// suppress an unrelated one. Each gets its own capping group, keyed by fact id.
    static func cappingKey(for fact: Fact) -> String {
        let channel = of(fact)
        return channel == .other ? "other:\(fact.id)" : channel.rawValue
    }

    /// What source-artifact channels do NOT catch, recorded so nobody mistakes
    /// `channelCapped` for a complete answer to correlated evidence.
    ///
    /// Correlation that crosses artifacts survives untouched. On the
    /// `jetsam-per-process-limit` fixture, `JetsamMemoryKillRule` scores 5 from
    /// `exception.subtype` (`EXC_RESOURCE ... MEMORY`, weight 3, `machException`) plus
    /// `termination.jetsam-per-process-limit` (weight 2, `termination`) — two artifacts,
    /// two channels, so capping changes nothing and the verdict still rests on one kernel
    /// decision to kill for memory, counted twice.
    ///
    /// The sharper case is `null-deref-small-offset`, where the weight-1 `registers.far`
    /// Fact is what lifts the score to `strong` even though
    /// `RegisterFactsExtractor`'s ground truth says `far.value` EQUALS the
    /// `exception.subtype` address the weight-3 Fact was parsed from. One number, two
    /// artifacts, and capping preserves the verdict.
    ///
    /// Catching either needs an event-level grouping this enum deliberately does not
    /// model, because "same event" cannot be derived from the payload and would have to be
    /// hand-declared per Fact — reintroducing exactly the drift that hand-tuned weights
    /// already suffer from.
    public static let residualCorrelationNote = """
        Channel capping collapses same-artifact correlation only. Cross-artifact \
        correlation (e.g. EXC_RESOURCE/MEMORY in `exception` alongside a jetsam \
        per-process-limit reason in `termination`) still scores as independent evidence.
        """
}
