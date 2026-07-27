import Foundation

/// `null-dereference`: `EXC_BAD_ACCESS` with a faulting address inside the null page
/// (below the architecture's page size — see `Architecture`). Branches its explanation on
/// `memory.fault-address-
/// exactly-null` (a raw nil-pointer dereference) vs a small nonzero offset (a field/ivar
/// access through a nil object/pointer — the offset is that field's byte offset).
///
/// GROUND TRUTH (corpus/fixtures/nullderef, real fixture): `far.value == 0`, matching
/// `exception.subtype`'s parsed address exactly. `registers.far` is cited at weight 0: it
/// is kept in `supporting` so the evidence citation stays visible (the register really did
/// corroborate the address), but it earns no score, because its value is a re-read of the
/// same number `memory.fault-address-null-page` already parsed out of `exception.subtype`,
/// not an independent observation. Scoring it at weight 1 (as this rule used to) let
/// `null-deref-small-offset` reach `strong` on that duplicate alone — see
/// `EvidenceChannel`'s doc for why source-artifact-based channel capping cannot catch this
/// (the two Facts come from different artifacts) and `docs/DESIGN.md`'s "Known limits of
/// the additive model" for the general problem this is one instance of.
///
/// CONTRADICTING EVIDENCE: when `vmregioninfo` places the faulting address inside a STACK
/// GUARD region, the kernel has *directly told us* what that memory is, which outranks the
/// null-page inference drawn from the address value alone. That fact is cited at weight 3
/// against this hypothesis so a shallow guard-page address (which can also be numerically
/// inside the null page — see `StackOverflowRule`'s co-firing note) surfaces as competing
/// hypotheses rather than a confident null-dereference verdict.
struct NullDereferenceRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard payload.exceptionType == "EXC_BAD_ACCESS" else { return [] }
        guard let nullPageFact = facts.first(where: { $0.id == "memory.fault-address-null-page" }) else { return [] }

        // Weights count INDEPENDENT observations, not restatements. `exception.type` is
        // this rule's own guard condition — it cannot fire without it, so it is not
        // evidence — and `memory.fault-address` is the same scalar the null-page fact
        // already reports. Counting all four gave this rule a floor of 5 while
        // stack-overflow topped out at 4, so a textbook stack overflow with 40 recursive
        // frames still came back "add a nil check".
        var supporting: [WeightedFact] = [WeightedFact(factID: nullPageFact.id, weight: 3)]

        let exactlyNull = facts.first { $0.id == "memory.fault-address-exactly-null" }
        if let exactlyNull { supporting.append(WeightedFact(factID: exactlyNull.id, weight: 1)) }

        if let farFact = facts.first(where: { $0.id == "registers.far" }),
           let address = MemoryFactsExtractor.faultAddress(in: payload)?.address,
           let faultingIdx = payload.faultingThreadIndex, payload.threads.indices.contains(faultingIdx),
           let threadState = payload.threads[faultingIdx].threadState,
           let far = RegisterFactsExtractor.registerValue(threadState, "far"),
           UInt64(bitPattern: Int64(far)) == address {
            supporting.append(WeightedFact(factID: farFact.id, weight: 0))
        }

        let explanation: String
        if exactlyNull != nil {
            explanation = """
            The faulting address is exactly 0 — a true nil-pointer dereference: code called through \
            a pointer/reference that was nil (an un-force-unwrapped Optional bridged to a raw \
            pointer, an uninitialized `weak`/`unowned` reference, or a C pointer that was never \
            checked). This is the clearest, least ambiguous EXC_BAD_ACCESS cause.
            """
        } else {
            let addr = facts.first(where: { $0.id == "memory.fault-address" })?.statement ?? "a small offset"
            explanation = """
            The faulting address is nonzero but still within the null page — \(addr). This \
            pattern is characteristic of a FIELD/ivar access through a nil object or nil struct \
            pointer: `nilObject.someField` compiles to a load at `nil + fieldOffset`, so the small \
            offset value is itself a clue to which field was being accessed at the failing call site.
            """
        }

        // A STACK GUARD region hit is a direct kernel observation about the faulting
        // address; it outranks the null-page inference. See this type's doc comment.
        var contradicting: [WeightedFact] = []
        if let guardFact = facts.first(where: { $0.id == "memory.fault-address-in-vmregion-stack-guard" }) {
            contradicting.append(WeightedFact(factID: guardFact.id, weight: 3))
        }

        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) { inspect.append(p) }

        return [Hypothesis(
            id: "null-dereference",
            title: "Null-pointer dereference",
            explanation: explanation,
            category: "memory",
            supporting: supporting,
            contradicting: contradicting,
            inspect: inspect,
            confirmFurtherBy: [
                "Add a nil-check/guard at the deepest app frame before the dereference",
                "Enable Address Sanitizer or run with NSZombies to catch the nil access closer to its origin",
            ]
        )]
    }
}
