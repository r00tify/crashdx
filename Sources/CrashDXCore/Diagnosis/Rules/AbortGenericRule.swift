import Foundation

/// `abort-generic`: SIGABRT via an `abort()`/`pthread_kill` chain, with no more specific
/// pattern identified. The honest fallback — deliberately low weight (1) so it never
/// outranks a more specific rule that fired strongly; Stage 3's ranking (not this rule)
/// is what keeps it below `cxx-terminate`/`uncaught-objc-exception` when they also fire.
struct AbortGenericRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        guard file.payload.exceptionSignal == "SIGABRT" else { return [] }
        guard let abortFact = facts.first(where: { $0.id == "frames.sentinel.abort-chain" }) else { return [] }

        let payload = file.payload
        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) { inspect.append(p) }

        let explanation = """
        The process received SIGABRT via an abort()/pthread_kill chain. This is the generic, honest \
        fallback: no more specific pattern (watchdog, jetsam, code-signing, C++ terminate, or an \
        uncaught NSException) was identified from the available evidence. Something in this process \
        explicitly called abort(), or a library detected a fatal condition and called it on its \
        behalf — inspect the frames immediately above the abort chain for the actual trigger.
        """

        return [Hypothesis(
            id: "abort-generic",
            title: "Process aborted (SIGABRT)",
            explanation: explanation,
            category: "abort",
            supporting: [WeightedFact(factID: abortFact.id, weight: 1)],
            contradicting: [],
            inspect: inspect,
            confirmFurtherBy: [
                "Inspect frames directly above the abort()/pthread_kill chain for the real trigger",
                "Check asi/console log around the crash time for an explicit abort message",
            ]
        )]
    }
}
