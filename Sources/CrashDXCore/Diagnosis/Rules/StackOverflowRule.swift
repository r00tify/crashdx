import Foundation

/// `stack-overflow`: `EXC_BAD_ACCESS` with a faulting address within the guard page
/// adjacent to the faulting thread's stack (`memory.fault-address-near-stack`, from
/// `MemoryFactsExtractor`: either within one page of `sp`, or `vmregioninfo` names a
/// STACK GUARD region). Base confidence is `moderate` by construction (weights sum to 3);
/// an additional `frames.recursion-pattern` fact (>= 3 consecutive identical symbols on
/// the faulting thread, from `FrameFactsExtractor`) adds +1, which is enough to cross into
/// `strong` — unbounded/runaway recursion is the most common real-world stack-overflow
/// cause, so corroborating it is deliberately decisive.
///
/// Explanation deliberately warns that the DEEPEST frames are likely victims (the last few
/// thousand call frames before the guard page, which may belong to entirely unrelated
/// code that simply happened to run out of stack), not the cause — the actual runaway
/// recursion (if any) is wherever the repeated symbol run in `frames.recursion-pattern`
/// points, or otherwise unknowable from the backtrace alone (it may be truncated).
///
/// Deliberately allowed to CO-FIRE with `null-dereference`: a very shallow guard-page
/// address can also be numerically inside the null page (< 0x4000) on a process whose
/// stack sits near the bottom of the address space. per CONTRIBUTING.md's "prefer a contradicting fact over suppressing a
/// competing rule",
/// this is presented as competing hypotheses, not suppressed.
struct StackOverflowRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard payload.exceptionType == "EXC_BAD_ACCESS" else { return [] }
        guard let nearStackFact = facts.first(where: { $0.id == "memory.fault-address-near-stack" }) else { return [] }

        // Two INDEPENDENT observations: where the address sits (the kernel naming a STACK
        // GUARD region, or proximity to sp) and the shape of the backtrace. `exception.type`
        // is the guard condition, not evidence, so it is no longer counted.
        var supporting: [WeightedFact] = [WeightedFact(factID: nearStackFact.id, weight: 3)]

        let recursionFact = facts.first { $0.id == "frames.recursion-pattern" }
        if let recursionFact { supporting.append(WeightedFact(factID: recursionFact.id, weight: 2)) }

        let recursionNote: String
        if let recursionFact {
            recursionNote = " A repeated-symbol recursion pattern was found on the faulting thread (\(recursionFact.statement)) — that repeated symbol is the likely runaway call site."
        } else {
            recursionNote = " No repeated-symbol recursion pattern was detected on the faulting thread; the overflow may come from many distinct large stack frames (e.g. deep non-recursive call chains, large local buffers) rather than simple recursion — inspect the full backtrace, not just its deepest frames."
        }

        let explanation = """
        The faulting address sits within the guard page adjacent to this thread's stack region — the \
        thread ran out of stack space and touched the unmapped page the kernel places just past it. \
        WARNING: the deepest frames in this backtrace are likely VICTIMS of running out of stack, not \
        the cause — whatever last happened to execute when the stack was already nearly exhausted. \
        The actual runaway growth (deep/unbounded recursion, or a very large stack frame) is usually \
        found by looking at the OVERALL shape of the backtrace, not its bottom.\(recursionNote)
        """

        var inspect: [InspectionPoint] = []
        if recursionFact != nil, let faultingIdx = payload.faultingThreadIndex,
           payload.threads.indices.contains(faultingIdx) {
            let frames = payload.threads[faultingIdx].frames
            // The recursion fact's statement cites "starting at frame N"; recompute the
            // index directly rather than parsing the statement text.
            if let idx = Self.recursionStartIndex(in: frames), frames.indices.contains(idx) {
                inspect.append(InspectionPoint(
                    threadIndex: faultingIdx, frameIndex: idx, leb: false,
                    symbol: frames[idx].symbol, sourceFile: frames[idx].sourceFile, sourceLine: frames[idx].sourceLine
                ))
            }
        }
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false),
           !inspect.contains(where: { $0.threadIndex == p.threadIndex && $0.frameIndex == p.frameIndex }) {
            inspect.append(p)
        }

        return [Hypothesis(
            id: "stack-overflow",
            title: "Stack overflow",
            explanation: explanation,
            category: "memory",
            supporting: supporting,
            contradicting: [],
            inspect: inspect,
            confirmFurtherBy: [
                "Look for unbounded/runaway recursion or a very large local stack buffer in the full backtrace",
                "Check for indirect recursion (A calls B calls A) that a simple repeated-symbol scan won't catch",
            ]
        )]
    }

    /// Mirrors `FrameFactsExtractor`'s consecutive-repeat scan to recover the start index
    /// for an `InspectionPoint`, without parsing the fact's human-readable statement text.
    private static func recursionStartIndex(in frames: [StackFrame]) -> Int? {
        guard frames.count >= 3 else { return nil }
        var i = 0
        while i <= frames.count - 3 {
            if let s = frames[i].symbol, frames[i + 1].symbol == s, frames[i + 2].symbol == s {
                return i
            }
            i += 1
        }
        return nil
    }
}
