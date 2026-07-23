import Foundation

/// `watchdog-timeout`: SpringBoard/FrontBoard killed the process for exceeding a
/// wall-clock time allowance (termination code `0x8badf00d`). See `docs/DESIGN.md`'s
/// Stage 2 rule catalog.
struct WatchdogTimeoutRule: DiagnosisRule {
    init() {}

    /// `Int("8badf00d", radix: 16)` — verified, not trusted from any doc excerpt.
    static let watchdogCode = 2_343_432_205
    static let watchdogNamespaces: Set<String> = ["SPRINGBOARD", "FRONTBOARD"]

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard let termination = payload.termination else { return [] }

        let code = diagnosisIntValue(termination["code"])
        let namespace = (termination["namespace"] as? String)?.uppercased()
        let codeMatches = code == Self.watchdogCode
        let namespaceMatches = namespace.map(Self.watchdogNamespaces.contains) ?? false
        let watchdogFact = facts.first { $0.id == "termination.watchdog-event" }

        // Fire on the pathognomonic code, or on a namespace + explicit watchdog-transgression
        // text (covers OS releases that phrase this differently).
        guard codeMatches || (namespaceMatches && watchdogFact != nil) else { return [] }

        var supporting: [WeightedFact] = []
        if codeMatches, let f = facts.first(where: { $0.id == "termination.code" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 3))
        }
        if namespaceMatches, let f = facts.first(where: { $0.id == "termination.namespace" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 1))
        }
        if let watchdogFact {
            supporting.append(WeightedFact(factID: watchdogFact.id, weight: 2))
        }

        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) {
            inspect.append(p)
        } else if let idx = payload.faultingThreadIndex, payload.threads.indices.contains(idx),
                  let frame0 = payload.threads[idx].frames.first {
            inspect.append(InspectionPoint(
                threadIndex: idx, frameIndex: 0, leb: false,
                symbol: frame0.symbol, sourceFile: frame0.sourceFile, sourceLine: frame0.sourceLine
            ))
        }

        let explanation = """
        SpringBoard/FrontBoard killed this process (termination code 0x8badf00d) for exceeding its \
        wall-clock time allowance on the main thread. The captured backtrace shows where the main \
        thread was STUCK at the moment the watchdog fired, not the location of the bug that caused \
        the stall — the actual cause is almost always earlier in the call chain: synchronous I/O, a \
        deadlock, or expensive work that should have been dispatched off the main thread.
        """

        return [Hypothesis(
            id: "watchdog-timeout",
            title: "Watchdog timeout (main thread stall)",
            explanation: explanation,
            category: "watchdog",
            supporting: supporting,
            contradicting: [],
            inspect: inspect,
            confirmFurtherBy: [
                "Correlate the stuck frame with synchronous network/disk calls or locks held at that call site",
                "Check for main-thread work that should be dispatched to a background queue",
            ]
        )]
    }
}
