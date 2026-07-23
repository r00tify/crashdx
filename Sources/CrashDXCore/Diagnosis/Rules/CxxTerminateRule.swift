import Foundation

/// `cxx-terminate`: an uncaught C++ exception reached `std::terminate` (a
/// `__cxa_throw`/`std::__terminate` chain on the faulting thread), distinct from an
/// Objective-C `NSException` even though ObjC exceptions ride the same C++ ABI.
///
/// GROUND TRUTH (nsexcrash, real fixture): its faulting thread contains BOTH `__cxa_throw`
/// AND `objc_exception_throw` — this is the first real test of the competing-hypotheses
/// model. This rule fires on the `__cxa_throw`/terminate-handler evidence (it doesn't know
/// or care what `uncaught-objc-exception` concludes), but explicitly treats a same-thread
/// `objc_exception_throw` sentinel as CONTRADICTING evidence, so Stage 3's scoring
/// naturally ranks it below the more specific ObjC rule when both fire.
struct CxxTerminateRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let cxaThrow = facts.first { $0.id == "frames.sentinel.cxa-throw" }
        let terminateHandler = facts.first { $0.id == "frames.sentinel.terminate-handler" }
        guard cxaThrow != nil || terminateHandler != nil else { return [] }

        var supporting: [WeightedFact] = []
        if let cxaThrow { supporting.append(WeightedFact(factID: cxaThrow.id, weight: 2)) }
        if let terminateHandler { supporting.append(WeightedFact(factID: terminateHandler.id, weight: 2)) }

        var contradicting: [WeightedFact] = []
        if let objcFact = facts.first(where: { $0.id == "frames.sentinel.objc-exception-throw" }) {
            contradicting.append(WeightedFact(factID: objcFact.id, weight: 2))
        }

        let payload = file.payload
        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) { inspect.append(p) }

        let explanation = """
        The faulting thread shows a __cxa_throw/std::__terminate chain: a C++ exception was thrown \
        and never caught, so the C++ runtime called std::terminate, which aborted the process. This \
        is the raw C++ exception path — distinct from an Objective-C NSException, which also rides \
        the C++ ABI internally but is reported by uncaught-objc-exception when that rule's more \
        specific markers (an objc_exception_throw frame with a lastExceptionBacktrace) are present.
        """

        return [Hypothesis(
            id: "cxx-terminate",
            title: "Uncaught C++ exception (std::terminate)",
            explanation: explanation,
            category: "cxx-exception",
            supporting: supporting,
            contradicting: contradicting,
            inspect: inspect,
            confirmFurtherBy: [
                "Find the throw site (search for `throw` near the deepest app frame)",
                "Wrap the call in try/catch, or install std::set_terminate for a diagnostic breadcrumb",
            ]
        )]
    }
}
