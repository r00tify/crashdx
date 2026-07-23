import Foundation

/// `uncaught-objc-exception`: an uncaught `NSException` walked up through
/// `objc_exception_throw` and was never caught.
///
/// GROUND TRUTH: a `lastExceptionBacktrace` present + an `objc_exception_throw`
/// sentinel frame is pathognomonic on its own; the classic `asi` "Terminating app due to
/// uncaught exception" message is corroboration ONLY when present — plain CLI/Foundation
/// processes never write it, so its absence must never be treated as evidence against this
/// hypothesis (no contradicting entry references it).
///
/// GROUND TRUTH: `inspect` points at the deepest app-image frame IN THE LEB,
/// using `resolveLEBFrameSymbol`'s preference for a same-offset thread frame's symbol when
/// the LEB's own symbol is suspect or conflicting.
struct UncaughtObjCExceptionRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        guard let lebPresent = facts.first(where: { $0.id == "leb.present" }) else { return [] }

        let lebObjcThrow = facts.first { $0.id == "leb.sentinel.objc-exception-throw" }
        let threadObjcThrow = facts.first { $0.id == "frames.sentinel.objc-exception-throw" }
        guard lebObjcThrow != nil || threadObjcThrow != nil else { return [] }

        var supporting: [WeightedFact] = [WeightedFact(factID: lebPresent.id, weight: 1)]
        if let lebObjcThrow {
            supporting.append(WeightedFact(factID: lebObjcThrow.id, weight: 3))
            if let threadObjcThrow {
                // Corroboration only — never required (the pathognomonic weight already
                // came from the LEB sentinel above).
                supporting.append(WeightedFact(factID: threadObjcThrow.id, weight: 1))
            }
        } else if let threadObjcThrow {
            // LEB is present but the throw sentinel only showed up on the faulting thread —
            // still pathognomonic for an uncaught ObjC exception.
            supporting.append(WeightedFact(factID: threadObjcThrow.id, weight: 3))
        }
        // ground truth: asi text is corroboration only; its absence is never counted
        // against this hypothesis (no contradicting entry is ever added for it).
        if let asiFact = facts.first(where: { $0.id == "asi.uncaught-exception-text" }) {
            supporting.append(WeightedFact(factID: asiFact.id, weight: 1))
        }

        let payload = file.payload
        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: true) {
            inspect.append(p)
        } else if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) {
            inspect.append(p)
        }

        let explanation = """
        A lastExceptionBacktrace is present and an objc_exception_throw frame appears in it (or on \
        the faulting thread) — together these are pathognomonic for an uncaught NSException: \
        `-raise` walked up through objc_exception_throw and was never caught, so the runtime called \
        terminate and aborted. The asi "Terminating app due to uncaught exception" message is only \
        corroboration when present; plain CLI/Foundation processes never write it, so its absence is \
        not evidence against this hypothesis.
        """

        return [Hypothesis(
            id: "uncaught-objc-exception",
            title: "Uncaught Objective-C exception (NSException)",
            explanation: explanation,
            category: "objc-exception",
            supporting: supporting,
            contradicting: [],
            inspect: inspect,
            confirmFurtherBy: [
                "Symbolicate the app frames in lastExceptionBacktrace to find the throw site",
                "Check the asi/console log for the exception name and reason, if available",
            ]
        )]
    }
}
